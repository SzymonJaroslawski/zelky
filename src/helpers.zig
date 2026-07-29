const std = @import("std");

const par = @import("./parser/parser.zig");
const com = @import("./vm/compiler.zig");

const Chunk = com.Chunk;
const OpCode = com.OpCode;

fn printIndent(depth: usize) void {
    for (0..depth) |_| {
        std.debug.print("  ", .{});
    }
}

pub fn printExpr(e: *const par.Expr) anyerror!void {
    switch (e.*) {
        .number => |n| std.debug.print("{d}", .{n}),
        .boolean => |b| std.debug.print("{}", .{b}),
        .string => |s| std.debug.print("\"{s}\"", .{s}),
        .variable => |v| std.debug.print("{s}", .{v}),
        .unary => |u| {
            std.debug.print("({s} ", .{@tagName(u.op)});
            try printExpr(u.operand);
            std.debug.print(")", .{});
        },
        .binary => |b| {
            std.debug.print("({s} ", .{@tagName(b.op)});
            try printExpr(b.left);
            std.debug.print(" ", .{});
            try printExpr(b.right);
            std.debug.print(")", .{});
        },
        .assign => |a| {
            std.debug.print("(assign {s} (", .{a.name});
            try printExpr(a.value);
            std.debug.print("))", .{});
        },
        .call => |c| {
            std.debug.print("(", .{});
            try printExpr(c.callee);
            std.debug.print("[", .{});
            for (c.args, 0..) |arg, i| {
                if (i > 0) std.debug.print(" ", .{}); // Added space between arguments
                try printExpr(arg);
            }
            std.debug.print("])", .{});
        },
    }
}

pub fn printStmt(s: *const par.Stmt, depth: usize) anyerror!void {
    printIndent(depth);

    switch (s.*) {
        .expr_stmt => |e| {
            std.debug.print("(expr ", .{});
            try printExpr(e);
            std.debug.print(")\n", .{});
        },

        .block => |stmts| {
            std.debug.print("(\n", .{});
            for (stmts) |*stmt| {
                try printStmt(stmt, depth + 1);
            }
            printIndent(depth);
            std.debug.print(")\n", .{});
        },

        .if_stmt => |i| {
            std.debug.print("(if ", .{});
            try printExpr(i.condition);
            std.debug.print("\n", .{});

            // Then branch
            try printStmt(i.then_branch, depth + 1);

            // Else branch
            if (i.else_branch) |else_b| {
                printIndent(depth);
                std.debug.print("else\n", .{});
                try printStmt(else_b, depth + 1);
            }

            printIndent(depth);
            std.debug.print(")\n", .{});
        },

        .let_stmt => |l| {
            std.debug.print("(let {s} = ", .{l.name});
            try printExpr(l.initializer);
            std.debug.print(")\n", .{});
        },

        .ret_stmt => |r| {
            std.debug.print("(return ", .{});
            try printExpr(r);
            std.debug.print(")\n", .{});
        },

        .fn_decl => |f| {
            std.debug.print("(fn {s}(", .{f.name});
            for (f.params, 0..) |param, idx| {
                std.debug.print("{s}", .{param});
                if (idx < f.params.len - 1) std.debug.print(", ", .{});
            }
            std.debug.print(")\n", .{});

            // Print the body (which is a statement, usually a block)
            try printStmt(f.body, depth + 1);

            printIndent(depth);
            std.debug.print(")\n", .{});
        },
    }
}

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
        .op_return_global, .op_return_local => blk: {
            const slot = chunk.code.items[offset + 1];
            std.debug.print("{s} slot {d}\n", .{ @tagName(op), slot });
            break :blk offset + 2;
        },
        // Everything else is a single byte with no operand.
        else => blk: {
            std.debug.print("{s}\n", .{@tagName(op)});
            break :blk offset + 1;
        },
    };
}
