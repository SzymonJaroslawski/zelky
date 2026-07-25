const std = @import("std");
const compiler = @import("./compiler.zig");

const Chunk = compiler.Chunk;
const Value = compiler.Value;
const OpCode = compiler.OpCode;

pub const VmError = error{
    StackUnderflow,
    TypeMismatch,
    OutOfMemory,
};

pub const Vm = struct {
    chunk: *const Chunk,
    ip: usize = 0,
    stack: std.ArrayList(Value),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, chunk: *const Chunk) !Vm {
        return .{ .chunk = chunk, .alloc = alloc, .stack = try std.ArrayList(Value).initCapacity(alloc, 50) };
    }

    pub fn deinit(self: *Vm) void {
        self.stack.deinit(self.alloc);
    }

    fn push(self: *Vm, val: Value) !void {
        try self.stack.append(self.alloc, val);
    }

    fn pop(self: *Vm) VmError!Value {
        return self.stack.pop() orelse VmError.StackUnderflow;
    }

    fn popNumber(self: *Vm) VmError!f64 {
        return switch (try self.pop()) {
            .number => |n| n,
            .boolean => VmError.TypeMismatch,
        };
    }

    fn peek(self: *Vm) !Value {
        return self.stack.items[self.stack.items.len - 1];
    }

    fn readU16(self: *Vm) u16 {
        const hi: u16 = self.chunk.code.items[self.ip];
        const lo: u16 = self.chunk.code.items[self.ip + 1];

        self.ip += 2;
        return (hi << 8) | lo;
    }

    pub fn run(self: *Vm) VmError!?Value {
        const op: OpCode = @enumFromInt(self.chunk.code.items[self.ip]);

        sw: switch (op) {
            inline else => |current_op| {
                self.ip += 1;
                switch (current_op) {
                    .op_constant => {
                        const idx = self.chunk.code.items[self.ip];
                        self.ip += 1;
                        try self.push(self.chunk.constants.items[idx]);

                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_true => {
                        try self.push(.{ .boolean = true });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_false => {
                        try self.push(.{ .boolean = false });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },

                    .op_add => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        try self.push(.{ .number = a + b });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_sub => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        try self.push(.{ .number = a - b });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_mul => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        try self.push(.{ .number = a * b });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_div => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        try self.push(.{ .number = a / b });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_negate => {
                        const a = try self.popNumber();
                        try self.push(.{ .number = -a });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_not => {
                        const a = try self.pop();
                        switch (a) {
                            .boolean => |bl| try self.push(.{ .boolean = !bl }),
                            .number => return VmError.TypeMismatch,
                        }
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },

                    .op_equal => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        try self.push(.{ .boolean = a == b });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_not_equal => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        try self.push(.{ .boolean = a != b });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_less => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        try self.push(.{ .boolean = a < b });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_less_equal => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        try self.push(.{ .boolean = a <= b });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_greater => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        try self.push(.{ .boolean = a > b });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },
                    .op_greater_equal => {
                        const b = try self.popNumber();
                        const a = try self.popNumber();
                        try self.push(.{ .boolean = a >= b });
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },

                    .op_pop => {
                        _ = try self.pop();
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },

                    .op_get_local => {
                        const slot = self.chunk.code.items[self.ip];
                        self.ip += 1;
                        try self.push(self.stack.items[slot]);
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },

                    .op_set_local => {
                        const slot = self.chunk.code.items[self.ip];
                        self.ip += 1;
                        self.stack.items[slot] = self.stack.items[self.stack.items.len - 1];
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },

                    .op_jump => {
                        const offset = self.readU16();
                        self.ip += offset;
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },

                    .op_jump_if_false => {
                        const offset = self.readU16();
                        const condition = try self.peek();
                        const is_false = switch (condition) {
                            .boolean => |bl| !bl,
                            .number => return VmError.TypeMismatch,
                        };

                        if (is_false) self.ip += offset;
                        continue :sw @enumFromInt(self.chunk.code.items[self.ip]);
                    },

                    .op_return => return try self.pop(),
                    .op_halt => return null,
                }
            },
        }
    }
};
