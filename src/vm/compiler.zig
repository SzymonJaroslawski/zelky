const std = @import("std");
const parser = @import("../parser/parser.zig");

pub const OpCode = enum(u8) {
    op_constant,
    op_true,
    op_false,
    op_add,
    op_sub,
    op_mul,
    op_div,
    op_negate,
    op_not,
    op_equal,
    op_not_equal,
    op_less,
    op_less_equal,
    op_greater,
    op_greater_equal,
    op_pop,
    op_jump_if_false,
    op_jump,
    op_get_local,
    op_set_local,
    op_return,
    op_halt,
};

pub const Value = union(enum) {
    number: f64,
    boolean: bool,
};

pub fn disassemble(chunk: *const Chunk, writer: *std.Io.Writer) !void {
    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = try disassembleInstruction(chunk, offset, writer);
    }
}

fn disassembleInstruction(chunk: *const Chunk, offset: usize, writer: *std.Io.Writer) !usize {
    try writer.print("{d:0>4}  ", .{offset});
    const op: OpCode = @enumFromInt(chunk.code.items[offset]);

    return switch (op) {
        .op_constant => blk: {
            const index = chunk.code.items[offset + 1];
            try writer.print("OP_CONSTANT      {d} ({any})\n", .{ index, chunk.constants.items[index] });
            break :blk offset + 2;
        },
        .op_get_local, .op_set_local => blk: {
            const slot = chunk.code.items[offset + 1];
            try writer.print("{s: <16} slot {d}\n", .{ @tagName(op), slot });
            break :blk offset + 2;
        },
        .op_jump, .op_jump_if_false => blk: {
            const jump_offset = (@as(u16, chunk.code.items[offset + 1]) << 8) | chunk.code.items[offset + 2];
            const target = offset + 3 + jump_offset;
            try writer.print("{s: <16} {d} -> {d}\n", .{ @tagName(op), offset, target });
            break :blk offset + 3;
        },
        // Everything else is a single byte with no operand.
        else => blk: {
            try writer.print("{s}\n", .{@tagName(op)});
            break :blk offset + 1;
        },
    };
}

pub const Chunk = struct {
    code: std.ArrayList(u8),
    constants: std.ArrayList(Value),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !Chunk {
        return .{
            .alloc = alloc,
            .code = try std.ArrayList(u8).initCapacity(alloc, 1024),
            .constants = try std.ArrayList(Value).initCapacity(alloc, 1024),
        };
    }

    pub fn deinit(self: *Chunk) void {
        self.code.deinit(self.alloc);
        self.constants.deinit(self.alloc);
    }

    pub fn emitOp(self: *Chunk, op: OpCode) !void {
        try self.code.append(self.alloc, @intFromEnum(op));
    }

    fn emitByte(self: *Chunk, byte: u8) !void {
        try self.code.append(self.alloc, byte);
    }

    fn emitConstant(self: *Chunk, val: Value) !void {
        try self.constants.append(self.alloc, val);
        const idx = self.constants.items.len - 1;
        if (idx > std.math.maxInt(u8)) return error.TooManyConstants;
        try self.emitOp(.op_constant);
        try self.emitByte(@intCast(idx));
    }

    fn emitJump(self: *Chunk, op: OpCode) !usize {
        try self.emitOp(op);
        try self.emitByte(0xff);
        try self.emitByte(0xff);

        return self.code.items.len - 2;
    }

    fn patchJump(self: *Chunk, offset: usize) !void {
        const distance = self.code.items.len - offset - 2;
        if (distance > std.math.maxInt(u16)) return error.JumpTooFar;

        self.code.items[offset] = @intCast((distance >> 8) & 0xff);
        self.code.items[offset + 1] = @intCast(distance & 0xff);
    }
};

const Local = struct {
    name: []const u8,
    depth: usize,
};

pub const Compiler = struct {
    chunk: *Chunk,
    locals: std.ArrayList(Local),
    scope_depth: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, chunk: *Chunk) !Compiler {
        return .{ .chunk = chunk, .locals = try std.ArrayList(Local).initCapacity(alloc, 0), .alloc = alloc };
    }

    pub fn deinit(self: *Compiler) void {
        self.locals.deinit(self.alloc);
    }

    fn begineScope(self: *Compiler) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *Compiler) !void {
        self.scope_depth -= 1;
        while (self.locals.items.len > 0 and self.locals.items[self.locals.items.len - 1].depth > self.scope_depth) {
            _ = self.locals.pop();
            try self.chunk.emitOp(.op_pop);
        }
    }

    fn declareLocal(self: *Compiler, name: []const u8) !void {
        if (self.locals.items.len >= std.math.maxInt(u8)) return error.TooManyLocals;
        try self.locals.append(self.alloc, .{ .name = name, .depth = self.scope_depth });
    }

    fn resolveLocal(self: *Compiler, name: []const u8) ?u8 {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) return @intCast(i);
        }
        return null;
    }

    pub fn compileExpr(self: *Compiler, expr: *const parser.Expr) !void {
        switch (expr.*) {
            .number => |n| try self.chunk.emitConstant(.{ .number = n }),
            .boolean => |b| try self.chunk.emitOp(if (b) .op_true else .op_false),
            .string => return error.StringsNotYetSupported,
            .variable => |name| {
                const slot = self.resolveLocal(name) orelse return error.UndefinedVariable;
                try self.chunk.emitOp(.op_get_local);
                try self.chunk.emitByte(slot);
            },

            .assign => |a| {
                try self.compileExpr(a.value);
                const slot = self.resolveLocal(a.name) orelse return error.UndefinedVariable;
                try self.chunk.emitOp(.op_set_local);
                try self.chunk.emitByte(slot);
            },

            .unary => |u| {
                try self.compileExpr(u.operand);
                switch (u.op) {
                    .minus => try self.chunk.emitOp(.op_negate),
                    .bang => try self.chunk.emitOp(.op_not),
                    else => unreachable,
                }
            },

            .binary => |b| {
                switch (b.op) {
                    .amp_amp => {
                        // Dead code elimination
                        if (b.left.* == .boolean and b.left.boolean == false) {
                            try self.compileExpr(b.left);
                            return;
                        }

                        try self.compileExpr(b.left);
                        const end_jump = try self.chunk.emitJump(.op_jump_if_false);
                        try self.chunk.emitOp(.op_pop);
                        try self.compileExpr(b.right);
                        try self.chunk.patchJump(end_jump);
                    },
                    .pipe_pipe => {
                        // a || b: if a is false pop and fall through to
                        // evaulate b. If a is true, jump straight past b,
                        // leaving a on the stack.

                        // Dead code elimination
                        if (b.left.* == .boolean and b.left.boolean == true) {
                            try self.compileExpr(b.left);
                            return;
                        }

                        try self.compileExpr(b.left);
                        const else_jump = try self.chunk.emitJump(.op_jump_if_false);
                        const end_jump = try self.chunk.emitJump(.op_jump);

                        try self.chunk.patchJump(else_jump);

                        try self.chunk.emitOp(.op_pop);
                        try self.compileExpr(b.right);
                        try self.chunk.patchJump(end_jump);
                    },
                    else => {
                        try self.compileExpr(b.left);
                        try self.compileExpr(b.right);
                        try self.chunk.emitOp(switch (b.op) {
                            .plus => .op_add,
                            .minus => .op_sub,
                            .star => .op_mul,
                            .slash => .op_div,
                            .eq_eq => .op_equal,
                            .bang_eq => .op_not_equal,
                            .lt => .op_less,
                            .lt_eq => .op_less_equal,
                            .gt => .op_greater,
                            .gt_eq => .op_greater_equal,
                            else => return error.UnsupportedOperator,
                        });
                    },
                }
            },
        }
    }

    pub fn compileStmt(self: *Compiler, stmt: *const parser.Stmt) !void {
        switch (stmt.*) {
            .expr_stmt => |e| {
                try self.compileExpr(e);
                try self.chunk.emitOp(.op_pop);
            },

            .block => |stmts| {
                self.begineScope();
                for (stmts) |*s| try self.compileStmt(s);
                try self.endScope();
            },

            .if_stmt => |i| {
                try self.compileExpr(i.condition);

                const then_jump = try self.chunk.emitJump(.op_jump_if_false);
                try self.chunk.emitOp(.op_pop);
                try self.compileStmt(i.then_branch);

                const else_jump = try self.chunk.emitJump(.op_jump);
                try self.chunk.patchJump(then_jump);
                try self.chunk.emitOp(.op_pop);

                if (i.else_branch) |else_branch| try self.compileStmt(else_branch);
                try self.chunk.patchJump(else_jump);
            },

            .let_stmt => |l| {
                try self.compileExpr(l.initializer);
                try self.declareLocal(l.name);
            },

            .ret_stmt => |r| {
                try self.compileExpr(r);
                try self.chunk.emitOp(.op_return);
            },
        }
    }
};
