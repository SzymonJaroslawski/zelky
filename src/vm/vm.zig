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

    /// Reads a single byte from code and advances the instruction pointer
    fn readByte(self: *CallFrame) u8 {
        const byte = self.function.chunk.code.items[self.ip];
        self.ip += 1;
        return byte;
    }

    /// Reads a 16-bit big-endian integer from code and advances the IP
    fn readU16(self: *CallFrame) u16 {
        const hi: u16 = self.readByte();
        const lo: u16 = self.readByte();
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

    fn peek(self: *const Vm) Value {
        return self.stack[self.stack_top - 1];
    }

    fn popNumber(self: *Vm) VmError!f64 {
        return switch (self.pop()) {
            .number => |n| n,
            .boolean, .function => VmError.TypeMismatch,
        };
    }

    inline fn popTwoNumbers(self: *Vm) VmError!struct { a: f64, b: f64 } {
        const b = try self.popNumber();
        const a = try self.popNumber();
        return .{ .a = a, .b = b };
    }

    fn getLocalNumber(self: *const Vm, frame: *const CallFrame, slot: usize) VmError!f64 {
        return switch (self.stack[slot + frame.base]) {
            .number => |n| n,
            else => VmError.TypeMismatch,
        };
    }

    inline fn localImmOp(self: *Vm, frame: *CallFrame) VmError!struct { local: f64, imm: f64 } {
        const slot = frame.readByte();
        const imm = frame.readByte();
        const local = try self.getLocalNumber(frame, slot);
        return .{ .local = local, .imm = @floatFromInt(imm) };
    }

    inline fn localLocalOp(self: *Vm, frame: *CallFrame) VmError!struct { a: f64, b: f64 } {
        const slot_a = frame.readByte();
        const slot_b = frame.readByte();
        const a = try self.getLocalNumber(frame, slot_a);
        const b = try self.getLocalNumber(frame, slot_b);
        return .{ .a = a, .b = b };
    }

    inline fn finishFrameReturn(self: *Vm, frame_ptr: **CallFrame, return_val: Value) ?Value {
        self.frames_top -= 1;
        if (self.frames_top == 0) return return_val;

        const finished_frame = self.frames[self.frames_top];
        self.stack_top = finished_frame.base - 1;
        self.push(return_val);

        frame_ptr.* = &self.frames[self.frames_top - 1];
        return null;
    }

    pub fn run(self: *Vm) VmError!?Value {
        var frame = &self.frames[self.frames_top - 1];
        const initial_op: OpCode = @enumFromInt(frame.function.chunk.code.items[frame.ip]);

        sw: switch (initial_op) {
            inline else => |current_op| {
                frame.ip += 1;

                switch (current_op) {
                    // Constants & Literals
                    .op_constant => {
                        const idx = frame.readByte();
                        self.push(frame.function.chunk.constants.items[idx]);
                    },
                    .op_true => self.push(.{ .boolean = true }),
                    .op_false => self.push(.{ .boolean = false }),

                    // Binary Math
                    .op_add => {
                        const ops = try self.popTwoNumbers();
                        self.push(.{ .number = ops.a + ops.b });
                    },
                    .op_sub => {
                        const ops = try self.popTwoNumbers();
                        self.push(.{ .number = ops.a - ops.b });
                    },
                    .op_mul => {
                        const ops = try self.popTwoNumbers();
                        self.push(.{ .number = ops.a * ops.b });
                    },
                    .op_div => {
                        const ops = try self.popTwoNumbers();
                        self.push(.{ .number = ops.a / ops.b });
                    },

                    // Unary Operations
                    .op_negate => {
                        const a = try self.popNumber();
                        self.push(.{ .number = -a });
                    },
                    .op_not => {
                        switch (self.pop()) {
                            .boolean => |bl| self.push(.{ .boolean = !bl }),
                            .number, .function => return VmError.TypeMismatch,
                        }
                    },

                    // Comparisons
                    .op_equal => {
                        const ops = try self.popTwoNumbers();
                        self.push(.{ .boolean = ops.a == ops.b });
                    },
                    .op_not_equal => {
                        const ops = try self.popTwoNumbers();
                        self.push(.{ .boolean = ops.a != ops.b });
                    },
                    .op_less => {
                        const ops = try self.popTwoNumbers();
                        self.push(.{ .boolean = ops.a < ops.b });
                    },
                    .op_less_equal => {
                        const ops = try self.popTwoNumbers();
                        self.push(.{ .boolean = ops.a <= ops.b });
                    },
                    .op_greater => {
                        const ops = try self.popTwoNumbers();
                        self.push(.{ .boolean = ops.a > ops.b });
                    },
                    .op_greater_equal => {
                        const ops = try self.popTwoNumbers();
                        self.push(.{ .boolean = ops.a >= ops.b });
                    },

                    // Local + Immediate Operations
                    .op_sub_local_imm => {
                        const args = try self.localImmOp(frame);
                        self.push(.{ .number = args.local - args.imm });
                    },
                    .op_plus_local_imm => {
                        const args = try self.localImmOp(frame);
                        self.push(.{ .number = args.local + args.imm });
                    },
                    .op_less_local_imm => {
                        const args = try self.localImmOp(frame);
                        self.push(.{ .boolean = args.local < args.imm });
                    },
                    .op_greater_local_imm => {
                        const args = try self.localImmOp(frame);
                        self.push(.{ .boolean = args.local > args.imm });
                    },

                    // Local + Local Operations
                    .op_add_local_local => {
                        const args = try self.localLocalOp(frame);
                        self.push(.{ .number = args.a + args.b });
                    },
                    .op_sub_local_local => {
                        const args = try self.localLocalOp(frame);
                        self.push(.{ .number = args.a - args.b });
                    },

                    // Variables
                    .op_pop => _ = self.pop(),
                    .op_get_local => {
                        const slot = frame.readByte();
                        self.push(self.stack[slot + frame.base]);
                    },
                    .op_set_local => {
                        const slot = frame.readByte();
                        self.stack[frame.base + slot] = self.peek();
                    },
                    .op_get_global => {
                        const slot = frame.readByte();
                        self.push(self.globals[slot]);
                    },
                    .op_define_global => {
                        const slot = frame.readByte();
                        std.debug.assert(slot < globals_max);
                        self.globals[slot] = self.pop();
                    },

                    // Control Flow
                    .op_jump => {
                        const offset = frame.readU16();
                        frame.ip += offset;
                    },
                    .op_jump_if_false => {
                        const offset = frame.readU16();
                        const condition = self.peek();

                        const is_false = switch (condition) {
                            .boolean => |bl| !bl,
                            .number, .function => return VmError.TypeMismatch,
                        };

                        if (is_false) frame.ip += offset;
                    },
                    .op_loop => {
                        const offset = frame.readU16();
                        frame.ip -= offset;
                    },
                    .op_call => {
                        const argc = frame.readByte();

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
                            .base = callee_idx + 1,
                        };
                        self.frames_top += 1;

                        frame = &self.frames[self.frames_top - 1];
                    },

                    // Returns
                    .op_return_local => {
                        const slot = frame.readByte();
                        const value = self.stack[slot + frame.base];
                        if (self.finishFrameReturn(&frame, value)) |ret| return ret;
                    },
                    .op_return_global => {
                        const slot = frame.readByte();
                        const value = self.globals[slot];
                        if (self.finishFrameReturn(&frame, value)) |ret| return ret;
                    },
                    .op_return => {
                        const result = self.pop();
                        if (self.finishFrameReturn(&frame, result)) |ret| return ret;
                    },

                    .op_halt => return null,
                }

                continue :sw @enumFromInt(frame.function.chunk.code.items[frame.ip]);
            },
        }
    }
};
