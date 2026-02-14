const std = @import("std");

var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

const Fingerprint = packed struct(u64) {
    id: u32,
    checksum: u32,

    fn int(f: Fingerprint) u64 {
        return @bitCast(f);
    }
};

const usage =
    \\usage: ziginit [options] <project name>
    \\
    \\options:
    \\  --help
    \\  --flake-package
    \\  --zig-version=[version]
    \\
;

fn fatal(err: anyerror) noreturn {
    std.process.fatal("{t}\n", .{err});
}

pub fn cutPrefix(comptime T: type, slice: []const T, prefix: []const T) ?[]const T {
    return if (std.mem.startsWith(T, slice, prefix)) slice[prefix.len..] else null;
}

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = (try std.process.argsAlloc(allocator))[1..];

    var pname: ?[]const u8 = null;
    var zig_version: std.SemanticVersion = .{ .major = 0, .minor = 15, .patch = 2 };
    var is_flake_package = false;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "--help")) {
                try stderr.writeAll(usage);
                try stderr.flush();
                return;
            } else if (std.mem.eql(u8, arg, "--flake-package")) {
                is_flake_package = true;
            } else if (cutPrefix(u8, arg, "--zig-version=")) |version| {
                zig_version = try .parse(version);
            } else {
                fatal(error.InvalidOption);
            }
        } else {
            if (pname != null) {
                fatal(error.DuplicateArgument);
            }
            pname = arg;
        }
    }

    const project_name = pname orelse fatal(error.MissingArgument);

    try std.fs.cwd().makeDir(project_name);

    const fingerprint: Fingerprint = .{
        .id = std.crypto.random.intRangeLessThan(u32, 1, 0xffffffff),
        .checksum = std.hash.Crc32.hash(project_name),
    };

    const project_dir = try std.fs.cwd().openDir(project_name, .{});
    try project_dir.makeDir("src");

    try writeFile(project_dir, "build.zig", build_zig, .{project_name});
    try writeFile(project_dir, "build.zig.zon", build_zig_zon, .{ project_name, fingerprint.int(), zig_version });
    try writeFile(project_dir, "src/main.zig", main_zig, .{});
    if (is_flake_package) {
        try writeFile(project_dir, "flake.nix", flake_package, .{zig_version});
    } else {
        try writeFile(project_dir, "flake.nix", flake, .{zig_version});
    }
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
    \\
    \\    const run_step = b.step("run", "Run the app");
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_step.dependOn(&run_cmd.step);
    \\
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\
    \\    if (b.args) |args| {{
    \\        run_cmd.addArgs(args);
    \\    }}
    \\}}
    \\
;

const build_zig_zon =
    \\.{{
    \\    .name = .{s},
    \\    .version = "0.1.0",
    \\    .fingerprint = 0x{x},
    \\    .minimum_zig_version = "{f}",
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
    \\            zig.packages.${{system}}."{f}"
    \\            zls.packages.${{system}}.zls
    \\          ];
    \\        }};
    \\      }});
    \\}}
    \\
;

const flake_package =
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
    \\  outputs =
    \\    {{
    \\      self,
    \\      nixpkgs,
    \\      zig,
    \\      zls,
    \\      flake-utils,
    \\    }}:
    \\    flake-utils.lib.eachDefaultSystem (
    \\      system:
    \\      let
    \\        lib = nixpkgs.lib;
    \\        fs = lib.fileset;
    \\        pkgs = import nixpkgs {{ inherit system; }};
    \\        version = "0.1.0";
    \\        zigPkg = zig.packages.${{system}}."{f}";
    \\      in
    \\      {{
    \\        devShells.default = pkgs.mkShell {{
    \\          nativeBuildInputs = [
    \\            zigPkg
    \\            zls.packages.${{system}}.zls
    \\          ];
    \\        }};
    \\
    \\        packages.default = pkgs.stdenvNoCC.mkDerivation {{
    \\          pname = "ziginit";
    \\          version = version;
    \\          src = fs.toSource {{
    \\            root = ./.;
    \\            fileset = fs.intersection (fs.fromSource (lib.sources.cleanSource ./.)) (
    \\              fs.unions [
    \\                ./src
    \\                ./build.zig
    \\                ./build.zig.zon
    \\              ]
    \\            );
    \\          }};
    \\
    \\          strictDeps = true;
    \\          nativeBuildInputs = [ zigPkg ];
    \\
    \\          zigBuildFlags = [
    \\            "-Doptimize=ReleaseSafe"
    \\          ];
    \\
    \\          configurePhase = ''
    \\            export ZIG_GLOBAL_CACHE_DIR=$TEMP/.cache
    \\          '';
    \\
    \\          buildPhase = ''
    \\            zig build install --color off --prefix $out
    \\          '';
    \\        }};
    \\      }}
    \\    );
    \\}}
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
