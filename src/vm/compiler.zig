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
            std.debug.print("Not debug build, no diagnostics\n", .{});
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

        // Free each dynamically allocated message buffer before freeing the list
        for (self.list.items) |diag| {
            self.alloc.free(diag.message);
        }
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

pub const Value = union(enum) {
    number: f64,
    boolean: bool,
    function: *const Function,
};

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
        for (self.constants.items) |val| {
            if (val == .function) {
                var func = @constCast(val.function);
                func.deinit();
                self.alloc.destroy(func);
            }
        }
        self.code.deinit(self.alloc);
        self.constants.deinit(self.alloc);
    }

    pub fn emitOp(self: *Chunk, op: OpCode) !void {
        try self.code.append(self.alloc, @intFromEnum(op));
    }

    pub fn emitByte(self: *Chunk, byte: u8) !void {
        try self.code.append(self.alloc, byte);
    }

    pub fn emitConstant(self: *Chunk, val: Value) !void {
        try self.constants.append(self.alloc, val);
        const idx = self.constants.items.len - 1;
        if (idx > std.math.maxInt(u8)) return error.TooManyConstants;
        try self.emitOp(.op_constant);
        try self.emitByte(@intCast(idx));
    }

    pub fn emitJump(self: *Chunk, op: OpCode) !usize {
        try self.emitOp(op);
        try self.emitByte(0xff);
        try self.emitByte(0xff);
        return self.code.items.len - 2;
    }

    pub fn patchJump(self: *Chunk, offset: usize) !void {
        const distance = self.code.items.len - offset - 2;
        if (distance > std.math.maxInt(u16)) return error.JumpTooFar;

        self.code.items[offset] = @intCast((distance >> 8) & 0xff);
        self.code.items[offset + 1] = @intCast(distance & 0xff);
    }
};

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

    fn beginScope(self: *Compiler) void {
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
                    .amp_amp => try self.compileAnd(b.left, b.right),
                    .pipe_pipe => try self.compileOr(b.left, b.right),
                    else => {
                        // Attempt superinstruction optimization before emitting standard bytecode
                        if (try self.tryEmitLocalLocal(b)) return;
                        if (try self.tryEmitLocalImm(b)) return;

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

    fn compileAnd(self: *Compiler, left: *const parser.Expr, right: *const parser.Expr) anyerror!void {
        if (left.* == .boolean and left.boolean == false) {
            try self.compileExpr(left);
            return;
        }
        if (right.* == .boolean and right.boolean == false) {
            try self.compileExpr(right);
            return;
        }

        try self.compileExpr(left);
        const end_jump = try self.chunk.emitJump(.op_jump_if_false);
        try self.chunk.emitOp(.op_pop);
        try self.compileExpr(right);
        try self.chunk.patchJump(end_jump);
    }

    fn compileOr(self: *Compiler, left: *const parser.Expr, right: *const parser.Expr) anyerror!void {
        if (left.* == .boolean and left.boolean == true) {
            try self.compileExpr(left);
            return;
        }
        if (right.* == .boolean and right.boolean == true) {
            try self.compileExpr(right);
            return;
        }

        try self.compileExpr(left);
        const else_jump = try self.chunk.emitJump(.op_jump_if_false);
        const end_jump = try self.chunk.emitJump(.op_jump);

        try self.chunk.patchJump(else_jump);
        try self.chunk.emitOp(.op_pop);
        try self.compileExpr(right);
        try self.chunk.patchJump(end_jump);
    }

    fn tryEmitLocalLocal(self: *Compiler, b: anytype) !bool {
        if ((b.op == .plus or b.op == .minus) and
            b.left.* == .variable and
            b.right.* == .variable)
        {
            if (self.resolveLocal(b.left.variable)) |slot_a| {
                if (self.resolveLocal(b.right.variable)) |slot_b| {
                    const op: OpCode = if (b.op == .plus) .op_add_local_local else .op_sub_local_local;
                    try self.chunk.emitOp(op);
                    try self.chunk.emitByte(slot_a);
                    try self.chunk.emitByte(slot_b);
                    return true;
                }
            }
        }
        return false;
    }

    fn tryEmitLocalImm(self: *Compiler, b: anytype) !bool {
        const is_supported_op = (b.op == .minus or b.op == .plus or b.op == .lt or b.op == .gt);
        if (is_supported_op and
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
                    else => unreachable,
                };
                try self.chunk.emitOp(op);
                try self.chunk.emitByte(slot);
                try self.chunk.emitByte(@intFromFloat(b.right.number));
                return true;
            }
        }
        return false;
    }

    pub fn compileStmt(self: *Compiler, stmt: *const parser.Stmt) !void {
        switch (stmt.*) {
            .expr_stmt => |e| {
                try self.compileExpr(e);
                try self.chunk.emitOp(.op_pop);
            },

            .block => |stmts| {
                self.beginScope();
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
