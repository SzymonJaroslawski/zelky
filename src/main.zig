const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

const szymciolang = @import("szymciolang");
const lex = @import("lexer/lexer.zig");
const par = @import("parser/parser.zig");
const lvm = @import("vm/vm.zig");
const com = @import("vm/compiler.zig");

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

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.page_allocator, false },
    };
    defer if (is_debug) {
        const check = debug_allocator.deinit();
        if (check == .leak) @panic("Memory leak detected!");
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    const alloc = arena.allocator();
    defer arena.deinit();

    const source =
        \\func ncr(n, k) {
        \\  if (k == 0 || k == n) { return 1; }
        \\  return ncr(n - 1, k - 1) + ncr(n - 1, k);
        \\}
        \\
        \\return ncr(24, 12);
    ;

    var lexer = lex.Lexer.init(source);
    var parser = par.Parser.init(alloc, &lexer);

    const stmt = parser.parseProgram() catch |err| {
        if (parser.diagnostic) |d| {
            std.debug.print("parse error at line {d}: {s} (got '{s}')\n", .{ d.line, d.message, d.lexeme });
        }
        return err;
    };

    try printStmt(&stmt, 0);

    var chunk = try com.Chunk.init(alloc);
    defer chunk.deinit();

    var globals = std.StringHashMap(u8).init(alloc);
    defer globals.deinit();

    var diags = try com.Diagnostics.init(alloc);
    defer diags.deinit();

    var compiler = try com.Compiler.init(alloc, &chunk, &globals, &diags);
    defer compiler.deinit();
    compiler.compileStmt(&stmt) catch |err| {
        if (diags.hasErrors()) {
            diags.printAll();
            //try com.disassemble(&chunk);
        }
        return err;
    };
    try chunk.emitOp(.op_halt);

    std.debug.print("\n---op code---\n", .{});
    for (chunk.constants.items) |cns| {
        const func = switch (cns) {
            .function => |f| f,
            else => continue,
        };

        std.debug.print("op code for function {s}:\n", .{func.name});
        try com.disassemble(&func.chunk);
    }

    var vm = try lvm.Vm.init(alloc, &chunk);
    defer vm.deinit();

    if (try vm.run()) |v| {
        std.debug.print("vm result: ", .{});
        switch (v) {
            .number => |n| std.debug.print("{d}\n", .{n}),
            .boolean => |b| std.debug.print("{}\n", .{b}),
            else => |any| std.debug.print("{any}\n", .{any}),
        }
    } else {
        std.debug.print("program halted with no return value\n", .{});
    }
}
