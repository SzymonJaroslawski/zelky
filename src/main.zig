const std = @import("std");
const builtin = @import("builtin");

const helpers = @import("./helpers.zig");
const lex = @import("lexer/lexer.zig");
const par = @import("parser/parser.zig");
const lvm = @import("vm/vm.zig");
const com = @import("vm/compiler.zig");

const Io = std.Io;

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
        \\let n = 0;
        \\for(let i = 0; i < 10; i = i + 1) {
        \\  n = n + i;
        \\}
        \\return n;
    ;

    var lexer = lex.Lexer.init(source);
    var parser = par.Parser.init(alloc, &lexer);

    const stmt = parser.parseProgram() catch |err| {
        if (parser.diagnostic) |d| {
            std.debug.print("parse error at line {d}: {s} (got '{s}')\n", .{ d.line, d.message, d.lexeme });
        }
        return err;
    };

    try helpers.printStmt(&stmt, 0);

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

    std.debug.print("\n---op code---\n", .{});
    try helpers.disassemble(&chunk);
    for (chunk.constants.items) |cns| {
        const func = switch (cns) {
            .function => |f| f,
            else => continue,
        };

        std.debug.print("op code for function {s}:\n", .{func.name});
        try helpers.disassemble(&func.chunk);
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
