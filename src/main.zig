const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const szymciolang = @import("szymciolang");
const lex = @import("lexer/lexer.zig");
const par = @import("parser/parser.zig");
const lvm = @import("vm/vm.zig");
const com = @import("vm/compiler.zig");

fn printExpr(e: *const par.Expr, writer: anytype) !void {
    switch (e.*) {
        .number => |n| try writer.print("{d}", .{n}),
        .boolean => |b| try writer.print("{}", .{b}),
        .string => |s| try writer.print("\"{s}\"", .{s}),
        .variable => |v| try writer.print("{s}", .{v}),
        .unary => |u| {
            try writer.print("({s} ", .{@tagName(u.op)});
            try printExpr(u.operand, writer);
            try writer.print(")", .{});
        },
        .binary => |b| {
            try writer.print("({s} ", .{@tagName(b.op)});
            try printExpr(b.left, writer);
            try writer.print(" ", .{});
            try printExpr(b.right, writer);
            try writer.print(")", .{});
        },
        .assign => {},
    }
}

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
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
        \\let a = 2;
        \\let b = 0;
        \\if (a != 2) {
        \\  b = 0;
        \\} else {
        \\  b = 67;
        \\}
        \\return b;
    ;

    var lexer = lex.Lexer.init(source);
    var parser = par.Parser.init(alloc, &lexer);

    const io = init.io;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer {
        stdout.flush() catch |err| {
            std.debug.print("flush error: {any}", .{err});
        };
    }

    const stmt = parser.parseProgram() catch |err| {
        if (parser.diagnostic) |d| {
            std.debug.print("parse error at line {d}: {s} (got '{s}')\n", .{ d.line, d.message, d.lexeme });
        }
        return err;
    };
    //try stdout.print("ast: ", .{});
    //try printExpr(expr, stdout);
    //try stdout.print("\n", .{});

    var chunk = try com.Chunk.init(alloc);
    defer chunk.deinit();

    var compiler = try com.Compiler.init(alloc, &chunk);
    defer compiler.deinit();
    try compiler.compileStmt(&stmt);
    try chunk.emitOp(.op_halt);

    try stdout.print("op code:\n", .{});
    try com.disassemble(&chunk, stdout);

    var vm = try lvm.Vm.init(alloc, &chunk);
    defer vm.deinit();

    if (try vm.run()) |v| {
        try stdout.print("vm result: ", .{});
        switch (v) {
            .number => |n| try stdout.print("{d}\n", .{n}),
            .boolean => |b| try stdout.print("{}\n", .{b}),
        }
    } else {
        try stdout.print("program halted with no return value\n", .{});
    }
}
