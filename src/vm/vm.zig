const std = @import("std");
const compiler = @import("./compiler.zig");

const Chunk = compiler.Chunk;
const Value = compiler.Value;
const OpCode = compiler.OpCode;
const Function = compiler.Function;

pub const VmError = error{
    TypeMismatch,
    OutOfMemory,
    NotCallable,
    ArityMismatch,
};

// VM Limits
const stack_max = 4096;
const globals_max = 2048;
const frames_max = 512;

const CallFrame = struct {
    function: *const Function,
    ip: usize = 0,
    /// Points to the starting index in the VM stack where this frame's locals begin
    base: usize,

    fn readU16(self: *CallFrame) u16 {
        const hi: u16 = self.function.chunk.code.items[self.ip];
        const lo: u16 = self.function.chunk.code.items[self.ip + 1];

        self.ip += 2;
        return (hi << 8) | lo;
    }
};

pub const Vm = struct {
    alloc: std.mem.Allocator,
    script: *Function,

    frames: [frames_max]CallFrame = undefined,
    frames_top: usize = 0,

    stack: [stack_max]Value = undefined,
    stack_top: usize = 0,

    globals: [globals_max]Value = undefined,

    pub fn init(alloc: std.mem.Allocator, chunk: *const Chunk) !Vm {
        const script = try alloc.create(Function);
        script.* = .{ .name = "<script>", .arity = 0, .chunk = chunk.*, .alloc = alloc };

        var vm: Vm = .{ .alloc = alloc, .script = script };

        // Initialize the base frame for the top-level script
        vm.frames[0] = .{ .function = script, .base = 0 };
        vm.frames_top = 1;

        return vm;
    }

    pub fn deinit(self: *Vm) void {
        self.alloc.destroy(self.script);
    }

    fn push(self: *Vm, val: Value) void {
        std.debug.assert(self.stack_top < stack_max);
        self.stack[self.stack_top] = val;
        self.stack_top += 1;
    }

    fn pop(self: *Vm) Value {
        std.debug.assert(self.stack_top > 0);
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    fn popNumber(self: *Vm) !f64 {
        return switch (self.pop()) {
            .number => |n| n,
            .boolean, .function => VmError.TypeMismatch,
        };
    }

    fn peek(self: *Vm) !Value {
        return self.stack[self.stack_top - 1];
    }

    pub fn run(self: *Vm) VmError!?Value {
        var frame = &self.frames[self.frames_top - 1];
        const initial_op: OpCode = @enumFromInt(frame.function.chunk.code.items[frame.ip]);

        // Using inline switch for bytecode dispatch. This compiles down to direct threaded code
        // (a computed goto), avoiding standard loop/switch overhead.
        sw: switch (initial_op) {
            inline else => |current_op| {
                frame.ip += 1;

                switch (current_op) {
                    // Constants & Literals
                    .op_constant => {
                        const idx = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;
                        self.push(frame.function.chunk.constants.items[idx]);
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_true => {
                        self.push(.{ .boolean = true });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_false => {
                        self.push(.{ .boolean = false });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },

                    // Binary Operations
                    .op_add => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        self.push(.{ .number = a + b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_sub => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        self.push(.{ .number = a - b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_mul => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        self.push(.{ .number = a * b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_div => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        self.push(.{ .number = a / b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },

                    // Unary Operations
                    .op_negate => {
                        const a = try self.popNumber();
                        self.push(.{ .number = -a });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_not => {
                        const a = self.pop();
                        switch (a) {
                            .boolean => |bl| self.push(.{ .boolean = !bl }),
                            .number, .function => return VmError.TypeMismatch,
                        }
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },

                    // Comparisons
                    .op_equal => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        self.push(.{ .boolean = a == b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_not_equal => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        self.push(.{ .boolean = a != b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_less => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        self.push(.{ .boolean = a < b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_less_equal => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        self.push(.{ .boolean = a <= b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_greater => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        self.push(.{ .boolean = a > b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_greater_equal => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        self.push(.{ .boolean = a >= b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },

                    // Local + Immediate Operations
                    .op_sub_local_imm => {
                        const slot = frame.function.chunk.code.items[frame.ip];
                        const imm = frame.function.chunk.code.items[frame.ip + 1];
                        frame.ip += 2;

                        const local = switch (self.stack[slot + frame.base]) {
                            .number => |n| n,
                            else => return VmError.TypeMismatch,
                        };
                        self.push(.{ .number = local - @as(f64, @floatFromInt(imm)) });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_plus_local_imm => {
                        const slot = frame.function.chunk.code.items[frame.ip];
                        const imm = frame.function.chunk.code.items[frame.ip + 1];
                        frame.ip += 2;

                        const local = switch (self.stack[slot + frame.base]) {
                            .number => |n| n,
                            else => return VmError.TypeMismatch,
                        };
                        self.push(.{ .number = local + @as(f64, @floatFromInt(imm)) });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_less_local_imm => {
                        const slot = frame.function.chunk.code.items[frame.ip];
                        const imm = frame.function.chunk.code.items[frame.ip + 1];
                        frame.ip += 2;

                        const local = switch (self.stack[slot + frame.base]) {
                            .number => |n| n,
                            else => return VmError.TypeMismatch,
                        };
                        self.push(.{ .boolean = local < @as(f64, @floatFromInt(imm)) });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]); // Bug Fix: removed +1 offset here
                    },
                    .op_greater_local_imm => {
                        const slot = frame.function.chunk.code.items[frame.ip];
                        const imm = frame.function.chunk.code.items[frame.ip + 1];
                        frame.ip += 2;

                        const local = switch (self.stack[slot + frame.base]) {
                            .number => |n| n,
                            else => return VmError.TypeMismatch,
                        };
                        self.push(.{ .boolean = local > @as(f64, @floatFromInt(imm)) });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]); // Bug Fix: removed +1 offset here
                    },

                    // Local + Local Operations
                    .op_add_local_local => {
                        const slot_a = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;
                        const slot_b = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;

                        const a = switch (self.stack[slot_a + frame.base]) {
                            .number => |n| n,
                            else => return VmError.TypeMismatch,
                        };

                        const b = switch (self.stack[slot_b + frame.base]) {
                            .number => |n| n,
                            else => return VmError.TypeMismatch,
                        };

                        self.push(.{ .number = a + b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_sub_local_local => {
                        const slot_a = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;
                        const slot_b = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;

                        const a = switch (self.stack[slot_a + frame.base]) {
                            .number => |n| n,
                            else => return VmError.TypeMismatch,
                        };

                        const b = switch (self.stack[slot_b + frame.base]) {
                            .number => |n| n,
                            else => return VmError.TypeMismatch,
                        };

                        self.push(.{ .number = a - b });
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },

                    // Variables
                    .op_pop => {
                        _ = self.pop();
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_get_local => {
                        const slot = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;
                        self.push(self.stack[slot + frame.base]);
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_set_local => {
                        const slot = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;
                        self.stack[frame.base + slot] = self.stack[self.stack_top - 1];
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_get_global => {
                        const slot = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;
                        self.push(self.globals[slot]);
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_define_global => {
                        const slot = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;
                        std.debug.assert(slot < globals_max);
                        self.globals[slot] = self.pop();
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },

                    // Control Flow
                    .op_jump => {
                        const offset = frame.readU16();
                        frame.ip += offset;
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_jump_if_false => {
                        const offset = frame.readU16();
                        const condition = try self.peek();

                        const is_false = switch (condition) {
                            .boolean => |bl| !bl,
                            .number, .function => return VmError.TypeMismatch,
                        };

                        if (is_false) frame.ip += offset;
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_call => {
                        const argc = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;

                        const callee_idx = self.stack_top - 1 - argc;
                        const callee = self.stack[callee_idx];

                        const function = switch (callee) {
                            .function => |f| f,
                            else => return VmError.NotCallable,
                        };

                        if (argc != function.arity) return VmError.ArityMismatch;

                        std.debug.assert(self.frames_top < frames_max);
                        self.frames[self.frames_top] = .{
                            .function = function,
                            .base = callee_idx + 1, // Arguments start immediately after the callable on the stack
                        };
                        self.frames_top += 1;

                        frame = &self.frames[self.frames_top - 1];
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },

                    .op_return_local => {
                        const slot = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;
                        const value = self.stack[slot + frame.base];

                        self.frames_top -= 1;
                        const finished_frame = self.frames[self.frames_top];
                        if (self.frames_top == 0) {
                            return value;
                        }

                        self.stack_top = finished_frame.base - 1;
                        self.push(value);

                        frame = &self.frames[self.frames_top - 1];
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },
                    .op_return_global => {
                        const slot = frame.function.chunk.code.items[frame.ip];
                        frame.ip += 1;
                        const value = self.globals[slot];

                        self.frames_top -= 1;
                        const finished_frame = self.frames[self.frames_top];
                        if (self.frames_top == 0) {
                            return value;
                        }

                        self.stack_top = finished_frame.base - 1;
                        self.push(value);

                        frame = &self.frames[self.frames_top - 1];
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },

                    .op_return => {
                        const result = self.pop();
                        self.frames_top -= 1;
                        const finished_frame = self.frames[self.frames_top];

                        if (self.frames_top == 0) {
                            return result;
                        }

                        // Wipe the local variables and the called function from the stack, replacing it with the return value
                        self.stack_top = finished_frame.base - 1;
                        self.push(result);

                        frame = &self.frames[self.frames_top - 1];
                        continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
                    },

                    .op_halt => return null,
                }
            },
        }
    }
};
