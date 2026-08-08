const std = @import("std");
const lex = @import("../lexer/lexer.zig");
const par = @import("../parser/parser.zig");
const com = @import("../vm/compiler.zig");

const helpers = @import("../helpers.zig");

const Globals = com.Globals;
const Chunk = com.Chunk;

pub const LoaderError = error{
    MoreThanOneMainFile,
    NoMainFile,
    CircularImport,
};

const ModuleState = enum { in_progress, done };
const ModuleCache = std.StringHashMap(ModuleState);

pub const Loader = struct {
    alloc: std.mem.Allocator,
    io_init: std.process.Init,
    globals: Globals,
    chunk: Chunk,
    cache: ModuleCache,
    diags: com.Diagnostics,

    pub fn init(alloc: std.mem.Allocator, io_init: std.process.Init) !Loader {
        return .{
            .alloc = alloc,
            .io_init = io_init,
            .globals = Globals.init(alloc),
            .chunk = try com.Chunk.init(alloc),
            .cache = ModuleCache.init(alloc),
            .diags = try com.Diagnostics.init(alloc),
        };
    }

    pub fn loadAndCompile(self: *Loader, path: []const u8, is_debug: bool) !Chunk {
        const main_abs_path = try self.findMain(path);
        try self.loadModule(main_abs_path, is_debug);
        return self.chunk;
    }

    fn readFile(self: *const Loader, path: []const u8) ![]const u8 {
        const io = self.io_init.io;
        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, std.Io.Limit.limited(1024 * 1024));
        return content;
    }

    fn resolveToAbsPath(self: *const Loader, path: []const u8) ![]const u8 {
        const io = self.io_init.io;
        return std.Io.Dir.cwd().realPathFileAlloc(io, path, self.alloc);
    }

    fn findMain(self: *const Loader, path: []const u8) ![]const u8 {
        const io = self.io_init.io;

        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("path: {s} does not exist.\n", .{path});
                return err;
            },
            else => return err,
        };

        const target_path = if (stat.kind == .directory)
            try std.Io.Dir.path.join(self.alloc, &.{ path, "main.zel" })
        else
            path;

        const abs_path = self.resolveToAbsPath(target_path) catch |err| switch (err) {
            error.FileNotFound => return LoaderError.NoMainFile,
            else => return err,
        };

        return abs_path;
    }

    fn loadModule(self: *Loader, path: []const u8, is_debug: bool) !void {
        const target_path = try self.resolveToAbsPath(path);
        if (self.cache.get(target_path)) |state| {
            switch (state) {
                .done => return,
                .in_progress => {
                    std.debug.print("circular import detected: {s}\n", .{target_path});
                    return LoaderError.CircularImport;
                },
            }
        }
        try self.cache.put(target_path, .in_progress);

        const dir = std.Io.Dir.path.dirname(target_path) orelse ".";

        const source = try self.readFile(target_path);
        var lexer = lex.Lexer.init(source);
        var parser = par.Parser.init(self.alloc, &lexer);

        const program = parser.parseProgram() catch |err| {
            if (parser.diagnostic) |d| {
                std.debug.print("parse error at line {d}: {s} (got '{s}')\n", .{ d.line, d.message, d.lexeme });
            }
            return err;
        };
        if (is_debug) {
            try helpers.printStmt(&program, 0);
        }

        for (program.block) |stmt| {
            if (stmt == .import_stmt) {
                const joined = try std.Io.Dir.path.join(self.alloc, &.{ dir, stmt.import_stmt.path });
                try self.loadModule(joined, is_debug);
            }
        }

        var compiler = try com.Compiler.init(self.alloc, &self.chunk, &self.globals, &self.diags);
        compiler.compileStmt(&program) catch |err| {
            if (self.diags.hasErrors()) {
                self.diags.printAll();
            }

            return err;
        };

        for (program.block) |stmt| {
            if (stmt == .fn_decl and !stmt.fn_decl.public) _ = self.globals.remove(stmt.fn_decl.name);
        }

        try self.cache.put(target_path, .done);
    }
};
