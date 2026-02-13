const std = @import("std");

var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len != 2) {
        try stderr.print("usage: {s} <project name>\n", .{if (args.len > 0) args[0] else "ziginit"});
        return error.MissingArgument;
    }

    const project_name = args[1];
    try std.fs.cwd().makeDir(project_name);

    const project_dir = try std.fs.cwd().openDir(project_name, .{});
    try project_dir.makeDir("src");

    try writeFile(project_dir, "build.zig", build_zig, .{project_name});
    try writeFile(project_dir, "build.zig.zon", build_zig_zon, .{project_name});
    try writeFile(project_dir, "src/main.zig", main_zig, .{});
    try writeFile(project_dir, "flake.nix", flake, .{});
    try writeFile(project_dir, ".envrc", envrc, .{});
    try writeFile(project_dir, ".gitignore", gitignore, .{});
}

fn writeFile(dir: std.fs.Dir, filename: []const u8, comptime content: []const u8, args: anytype) !void {
    const file = try dir.createFile(filename, .{ .truncate = false });
    defer file.close();

    var file_buffer: [1024]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    const writer = &file_writer.interface;

    try writer.print(content, args);
    try writer.flush();
}

const build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {{
    \\    const target = b.standardTargetOptions(.{{}});
    \\    const optimize = b.standardOptimizeOption(.{{}});
    \\
    \\    const exe = b.addExecutable(.{{
    \\        .name = "{s}",
    \\        .root_module = b.createModule(.{{
    \\            .root_source_file = b.path("src/main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\        }}),
    \\    }});
    \\
    \\    b.installArtifact(exe);
    \\}}
    \\
;

const build_zig_zon =
    \\.{{
    \\    .name = .{s},
    \\    .version = "0.0.0",
    \\    .fingerprint = 0x8c736521f9f54213,
    \\    .minimum_zig_version = "0.15.2",
    \\    .dependencies = .{{}},
    \\    .paths = .{{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    }},
    \\}}
    \\
;

const main_zig =
    \\const std = @import("std");
    \\
    \\pub fn main() !void {{
    \\    std.debug.print("All your {{s}} are belong to us.\n", .{{"codebase"}});
    \\}}
    \\
;

const flake =
    \\
    \\{{
    \\  description = "zig flake";
    \\
    \\  inputs = {{
    \\    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    \\    zig.url = "github:mitchellh/zig-overlay";
    \\    zls.url = "github:zigtools/zls";
    \\    flake-utils.url = "github:numtide/flake-utils";
    \\  }};
    \\
    \\  outputs = {{ self, nixpkgs, zig, zls, flake-utils }}:
    \\    flake-utils.lib.eachDefaultSystem (system:
    \\      let
    \\        pkgs = import nixpkgs {{ inherit system; }};
    \\      in {{
    \\        devShells.default = pkgs.mkShell {{
    \\          nativeBuildInputs = [
    \\            zig.packages.${{system}}."0.15.2"
    \\            zls.packages.${{system}}.zls
    \\          ];
    \\        }};
    \\      }});
    \\}}
    \\
;

const envrc =
    \\use flake
    \\
;

const gitignore =
    \\.zig-cache
    \\zig-out
    \\
;
