const std = @import("std");
const builtin = @import("builtin");

const helpers = @import("./helpers.zig");
const load = @import("./module/loader.zig");
const lvm = @import("./vm/vm.zig");

const Io = std.Io;
const build_opt = @import("build_options");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
    std.debug.print("Zelky version: {s}\n", .{build_opt.version});

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

    const args = try init.minimal.args.toSlice(alloc);
    const path = args[1];

    var loader = try load.Loader.init(alloc, init);
    var chunk = try loader.loadAndCompile(path, is_debug);

    //std.debug.print("\n---op code---\n", .{});
    //try helpers.disassemble(&chunk);
    //for (chunk.constants.items) |cns| {
    //   const func = switch (cns) {
    //       .function => |f| f,
    //       else => continue,
    //   };
    //
    //    std.debug.print("op code for function {s}:\n", .{func.name});
    //    try helpers.disassemble(&func.chunk);
    //}

    var vm = try lvm.Vm.init(alloc, &chunk);

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
