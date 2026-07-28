const std = @import("std");
const builtin = @import("builtin");

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
    op_get_global,
    op_set_local,
    op_define_global,
    op_call,
    op_return,
    op_halt,

    // Superinstructions
    op_sub_local_imm,
    op_plus_local_imm,
    op_greater_local_imm,
    op_less_local_imm,

    op_add_local_local,
    op_sub_local_local,
};

const is_debug = builtin.mode == .Debug;

pub const Diagnostic = struct {
    message: []u8,
};

pub const Diagnostics = struct {
    list: if (is_debug) std.ArrayList(Diagnostic) else void,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !Diagnostics {
        if (!is_debug) {
            std.debug.print("Not debug build, no diagnostics", .{});

            return .{
                .list = {},
                .alloc = alloc,
            };
        }

        return .{
            .list = try std.ArrayList(Diagnostic).initCapacity(alloc, 0),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Diagnostics) void {
        if (!is_debug) return;

        self.list.deinit(self.alloc);
    }

    pub fn report(self: *Diagnostics, comptime format: []const u8, args: anytype) error{ CompileError, OutOfMemory }!void {
        if (!is_debug) return;

        const msg = try std.fmt.allocPrint(self.alloc, format, args);
        try self.list.append(self.alloc, .{ .message = msg });
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        if (!is_debug) return false;

        return self.list.items.len > 0;
    }

    pub fn printAll(self: *const Diagnostics) void {
        if (!is_debug) return;

        for (self.list.items) |diag| {
            std.debug.print("Compile error: {s}\n", .{diag.message});
        }
    }
};

pub const Globals = std.StringHashMap(u8);

pub const Function = struct {
    name: []const u8 = "",
    arity: usize = 0,
    chunk: Chunk,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !Function {
        return .{
            .alloc = alloc,
            .chunk = try Chunk.init(alloc),
        };
    }

    pub fn deinit(self: *Function) void {
        self.chunk.deinit();
    }

    pub fn compile(self: *Function, fndec: *const parser.FnDecl, globals: *Globals, diags: *Diagnostics) anyerror!void {
        var compl = try Compiler.init(self.alloc, &self.chunk, globals, diags);
        defer compl.deinit();

        self.name = fndec.name;
        self.arity = fndec.params.len;

        for (fndec.params) |param| {
            try compl.declareLocal(param);
        }

        try compl.compileStmt(fndec.body);

        try self.chunk.emitConstant(.{ .number = 0 });
        try self.chunk.emitOp(.op_return);
    }
};

pub const Value = union(enum) {
    number: f64,
    boolean: bool,
    function: *const Function,
};

pub fn disassemble(chunk: *const Chunk) !void {
    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = try disassembleInstruction(chunk, offset);
    }
}

fn disassembleInstruction(chunk: *const Chunk, offset: usize) !usize {
    std.debug.print("{d:0>4}  ", .{offset});
    const op: OpCode = @enumFromInt(chunk.code.items[offset]);

    return switch (op) {
        .op_constant => blk: {
            const index = chunk.code.items[offset + 1];
            std.debug.print("OP_CONSTANT      {d} ({any})\n", .{ index, chunk.constants.items[index] });
            break :blk offset + 2;
        },
        .op_get_local, .op_set_local, .op_get_global, .op_define_global => blk: {
            const slot = chunk.code.items[offset + 1];
            std.debug.print("{s: <16} slot {d}\n", .{ @tagName(op), slot });
            break :blk offset + 2;
        },
        .op_call => blk: {
            const argc = chunk.code.items[offset + 1];
            std.debug.print("OP_CALL          argc {d}\n", .{argc});
            break :blk offset + 2;
        },
        .op_sub_local_imm, .op_less_local_imm => blk: {
            const slot = chunk.code.items[offset + 1];
            const imm = chunk.code.items[offset + 2];
            std.debug.print("{s: <16} slot {d}, imm {d}\n", .{ @tagName(op), slot, imm });
            break :blk offset + 3;
        },
        .op_jump, .op_jump_if_false => blk: {
            const jump_offset = (@as(u16, chunk.code.items[offset + 1]) << 8) | chunk.code.items[offset + 2];
            const target = offset + 3 + jump_offset;
            std.debug.print("{s: <16} {d} -> {d}\n", .{ @tagName(op), offset, target });
            break :blk offset + 3;
        },
        // Everything else is a single byte with no operand.
        else => blk: {
            std.debug.print("{s}\n", .{@tagName(op)});
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
            .code = try std.ArrayList(u8).initCapacity(alloc, 256),
            .constants = try std.ArrayList(Value).initCapacity(alloc, 32),
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
    globals: *Globals,
    diags: *Diagnostics,

    pub fn init(alloc: std.mem.Allocator, chunk: *Chunk, globals: *Globals, diags: *Diagnostics) !Compiler {
        return .{
            .chunk = chunk,
            .locals = try std.ArrayList(Local).initCapacity(alloc, 16),
            .alloc = alloc,
            .globals = globals,
            .diags = diags,
        };
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

    pub fn declareLocal(self: *Compiler, name: []const u8) !void {
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
                if (self.resolveLocal(name)) |slot| {
                    try self.chunk.emitOp(.op_get_local);
                    try self.chunk.emitByte(slot);
                    return;
                }

                if (self.globals.get(name)) |slot| {
                    try self.chunk.emitOp(.op_get_global);
                    try self.chunk.emitByte(slot);
                    return;
                }

                try self.diags.report("Undefined variable '{s}'.", .{name});
                return error.UndefinedVariable;
            },

            .assign => |a| {
                try self.compileExpr(a.value);
                const slot = self.resolveLocal(a.name) orelse {
                    try self.diags.report("Cannot assign to undefined variable '{s}'.", .{a.name});
                    return error.UndefinedVariable;
                };
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

            .call => |c| {
                try self.compileExpr(c.callee);
                for (c.args) |arg| try self.compileExpr(arg);
                try self.chunk.emitOp(.op_call);
                if (c.args.len > std.math.maxInt(u8)) return error.TooManyArguments;
                try self.chunk.emitByte(@intCast(c.args.len));
            },

            .binary => |b| {
                switch (b.op) {
                    .amp_amp => {
                        // Dead code elimination
                        if (b.left.* == .boolean and b.left.boolean == false) {
                            try self.compileExpr(b.left);
                            return;
                        }

                        if (b.right.* == .boolean and b.right.boolean == false) {
                            try self.compileExpr(b.right);
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

                        if (b.right.* == .boolean and b.right.boolean == true) {
                            try self.compileExpr(b.right);
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
                        //Superinstructions

                        // op_add_local_local, op_sub_local_local
                        if (b.op == .plus and b.left.* == .variable and b.right.* == .variable) {
                            if (self.resolveLocal(b.left.variable)) |slot_a| {
                                if (self.resolveLocal(b.right.variable)) |slot_b| {
                                    try self.chunk.emitOp(.op_add_local_local);

                                    try self.chunk.emitByte(slot_a);
                                    try self.chunk.emitByte(slot_b);
                                    return;
                                }
                            }
                        }
                        if (b.op == .minus and b.left.* == .variable and b.right.* == .variable) {
                            if (self.resolveLocal(b.left.variable)) |slot_a| {
                                if (self.resolveLocal(b.right.variable)) |slot_b| {
                                    try self.chunk.emitOp(.op_sub_local_local);

                                    try self.chunk.emitByte(slot_a);
                                    try self.chunk.emitByte(slot_b);
                                    return;
                                }
                            }
                        }

                        // op_sub_local_imm, op_plus_local_imm, op_less_local_imm, op_greater_local_imm
                        if (((b.op == .minus or b.op == .plus) or (b.op == .lt or b.op == .gt)) and
                            b.left.* == .variable and
                            b.right.* == .number and
                            b.right.number >= 0 and
                            b.right.number <= 255 and
                            b.right.number == @trunc(b.right.number))
                        {
                            if (self.resolveLocal(b.left.variable)) |slot| {
                                const op: OpCode = switch (b.op) {
                                    .minus => .op_sub_local_imm,
                                    .plus => .op_plus_local_imm,
                                    .lt => .op_less_local_imm,
                                    .gt => .op_greater_local_imm,
                                    else => return error.Unreachable,
                                };
                                try self.chunk.emitOp(op);

                                try self.chunk.emitByte(slot);
                                try self.chunk.emitByte(@intFromFloat(b.right.number));

                                return;
                            }
                        }

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

            .fn_decl => |*f| {
                const slot: u8 = @intCast(self.globals.count());
                try self.globals.put(f.name, slot);

                const function = try self.alloc.create(Function);
                function.* = try Function.init(self.alloc);

                try function.compile(f, self.globals, self.diags);

                try self.chunk.emitConstant(.{ .function = function });
                try self.chunk.emitOp(.op_define_global);
                try self.chunk.emitByte(slot);
            },
        }
    }
};
