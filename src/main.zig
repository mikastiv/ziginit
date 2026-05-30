const std = @import("std");

const Fingerprint = packed struct(u64) {
    id: u32,
    checksum: u32,

    fn int(f: Fingerprint) u64 {
        return @bitCast(f);
    }
};

const ZigVersion = union(enum) {
    semver: std.SemanticVersion,
    nightly,
};

const usage =
    \\usage: ziginit [options] <project name>
    \\
    \\options:
    \\  -h, --help                 print help text
    \\  --flake-package            initialize the flake as a package also
    \\  --no-cc                    use the NoCC nix environment
    \\  --zig-version=[version]    set the zig compiler version (also accepts nightly)
    \\
;

fn fatal(err: anyerror) noreturn {
    std.process.fatal("{t}", .{err});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = (try init.minimal.args.toSlice(allocator))[1..];

    var pname: ?[]const u8 = null;
    var zig_version: ZigVersion = .{ .semver = .{ .major = 0, .minor = 16, .patch = 0 } };
    var is_flake_package = false;
    var no_cc = false;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try stderr.writeAll(usage);
                try stderr.flush();
                return;
            } else if (std.mem.eql(u8, arg, "--flake-package")) {
                is_flake_package = true;
            } else if (std.mem.eql(u8, arg, "--no-cc")) {
                no_cc = true;
            } else if (std.mem.cutPrefix(u8, arg, "--zig-version=")) |version| {
                if (std.mem.eql(u8, version, "nightly"))
                    zig_version = .nightly
                else
                    zig_version = .{ .semver = try .parse(version) };
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

    const nix_zig_version: []const u8 = blk: {
        break :blk switch (zig_version) {
            .nightly => "nightly",
            .semver => |version| try std.fmt.allocPrint(allocator, "zig_{d}_{d}_{d}", .{ version.major, version.minor, version.patch }),
        };
    };

    const zig_version_str: []const u8 = switch (zig_version) {
        .nightly => try fetchNightyVersion(allocator, io),
        .semver => |version| try std.fmt.allocPrint(allocator, "{f}", .{version}),
    };

    var project_name: std.ArrayList(u8) = .empty;
    if (pname) |name|
        try project_name.appendSlice(allocator, name)
    else
        fatal(error.MissingArgument);

    std.mem.replaceScalar(u8, project_name.items, '-', '_');
    std.mem.replaceScalar(u8, project_name.items, ' ', '_');

    var i: usize = 0;
    while (i < project_name.items.len) {
        project_name.items[i] = std.ascii.toLower(project_name.items[i]);
        if (!std.ascii.isAlphanumeric(project_name.items[i]) and project_name.items[i] != '_') {
            _ = project_name.orderedRemove(i);
            continue;
        }

        i += 1;
    }

    if (std.ascii.isDigit(project_name.items[0])) {
        try project_name.insert(allocator, 0, '_');
    }

    try std.Io.Dir.cwd().createDir(io, pname.?, .default_dir);

    const rng_impl: std.Random.IoSource = .{ .io = io };
    const rng = rng_impl.interface();

    const fingerprint: Fingerprint = .{
        .id = rng.intRangeLessThan(u32, 1, 0xffffffff),
        .checksum = std.hash.Crc32.hash(project_name.items),
    };

    const project_dir = try std.Io.Dir.cwd().openDir(io, pname.?, .{});
    try project_dir.createDir(io, "src", .default_dir);

    const no_cc_str: []const u8 = if (no_cc) "NoCC" else "";

    try writeFile(io, project_dir, "build.zig", build_zig, .{project_name.items});
    try writeFile(io, project_dir, "build.zig.zon", build_zig_zon, .{ project_name.items, fingerprint.int(), zig_version_str });
    try writeFile(io, project_dir, "src/main.zig", main_zig, .{});
    if (is_flake_package) {
        try writeFile(io, project_dir, "flake.nix", flake_package, .{ nix_zig_version, no_cc_str, no_cc_str, project_name.items, project_name.items });
        try writeFile(io, project_dir, "deps.nix", deps, .{});
    } else {
        try writeFile(io, project_dir, "flake.nix", flake, .{ nix_zig_version, no_cc_str });
    }
    try writeFile(io, project_dir, ".envrc", envrc, .{});
    try writeFile(io, project_dir, ".gitignore", gitignore, .{});

    _ = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "init" },
        .cwd = .{ .dir = project_dir },
    });

    _ = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "add", "." },
        .cwd = .{ .dir = project_dir },
    });
}

fn writeFile(io: std.Io, dir: std.Io.Dir, filename: []const u8, comptime content: []const u8, args: anytype) !void {
    const file = try dir.createFile(io, filename, .{ .truncate = false });
    defer file.close(io);

    var file_buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    const writer = &file_writer.interface;

    try writer.print(content, args);
    try writer.flush();
}

fn fetchNightyVersion(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = "https://ziglang.org/download/index.json" },
        .response_writer = &body_writer.writer,
    });

    if (response.status != .ok) return error.InvalidResponse;

    const json = try std.json.parseFromSlice(std.json.Value, allocator, body_writer.written(), .{});
    defer json.deinit();

    const master = json.value.object.get("master") orelse return error.NoMasterField;
    const version = master.object.get("version") orelse return error.NoVersionField;

    return try allocator.dupe(u8, version.string);
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
    \\    .minimum_zig_version = "{s}",
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
    \\{{
    \\  description = "zig flake";
    \\
    \\  inputs = {{
    \\    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    \\
    \\    zig-flake.url = "github:silversquirl/zig-flake";
    \\    zig-flake.inputs.nixpkgs.follows = "nixpkgs";
    \\  }};
    \\
    \\  outputs =
    \\    {{
    \\      self,
    \\      nixpkgs,
    \\      zig-flake,
    \\    }}:
    \\    let
    \\      forAllSystems =
    \\        f:
    \\        builtins.mapAttrs (
    \\          system: pkgs: f pkgs zig-flake.packages.${{system}}.{s}
    \\        ) nixpkgs.legacyPackages;
    \\    in
    \\    {{
    \\      devShells = forAllSystems (
    \\        pkgs: zig: {{
    \\          default = pkgs.mkShell{s} {{
    \\            nativeBuildInputs = [
    \\              zig
    \\              zig.zls
    \\            ];
    \\          }};
    \\        }}
    \\      );
    \\    }};
    \\}}
;

const flake_package =
    \\{{
    \\  description = "zig flake";
    \\
    \\  inputs = {{
    \\    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    \\
    \\    zig-flake.url = "github:silversquirl/zig-flake";
    \\    zig-flake.inputs.nixpkgs.follows = "nixpkgs";
    \\  }};
    \\
    \\  outputs =
    \\    {{
    \\      self,
    \\      nixpkgs,
    \\      zig-flake,
    \\    }}:
    \\    let
    \\      lib = nixpkgs.lib;
    \\      fs = lib.fileset;
    \\      forAllSystems =
    \\        f:
    \\        builtins.mapAttrs (
    \\          system: pkgs: f system pkgs zig-flake.packages.${{system}}.{s}
    \\        ) nixpkgs.legacyPackages;
    \\    in
    \\    {{
    \\      devShells = forAllSystems (
    \\        system: pkgs: zig: {{
    \\          default = pkgs.mkShell{s} {{
    \\            nativeBuildInputs = [
    \\              zig
    \\              zig.zls
    \\            ];
    \\          }};
    \\        }}
    \\      );
    \\
    \\      packages = forAllSystems (
    \\        system: pkgs: zig: {{
    \\          default = pkgs.stdenv{s}.mkDerivation {{
    \\            name = "{s}";
    \\            version = "0.1.0";
    \\            meta.mainProgram = "{s}";
    \\            src = fs.toSource {{
    \\              root = ./.;
    \\              fileset = fs.intersection (fs.fromSource (lib.sources.cleanSource ./.)) (
    \\                fs.unions [
    \\                  ./src
    \\                  ./build.zig
    \\                  ./build.zig.zon
    \\                  ./deps.nix
    \\                ]
    \\              );
    \\            }};
    \\
    \\            nativeBuildInputs = [ zig ];
    \\            dontInstall = true;
    \\            strictDeps = true;
    \\
    \\            configurePhase = ''
    \\              export ZIG_GLOBAL_CACHE_DIR=$TEMP/.cache
    \\              PACKAGE_DIR=${{pkgs.callPackage ./deps.nix {{ }}}}
    \\            '';
    \\
    \\            buildPhase = ''
    \\              zig build install --system $PACKAGE_DIR -Doptimize=ReleaseSafe --color off --prefix $out
    \\            '';
    \\          }};
    \\        }}
    \\      );
    \\    }};
    \\}}
;

const deps =
    \\{{
    \\  linkFarm,
    \\  fetchzip,
    \\  fetchgit,
    \\}}:
    \\linkFarm "zig-packages" [
    \\  {{
    \\#   name = "mksv-0.0.1-SesxeIg4AAAxnAqrX4eSfBB-mFjYmbWpbgdfOWOZ2UU_";
    \\#   path = fetchgit {{
    \\#     url = "https://codeberg.org/mikastiv/mksv.git";
    \\#     rev = "30c8d2fc97ba3d09764a3990b4f1516768fa6927";
    \\#     hash = "sha256-ThaqFunjhGmi3XrJnF299GSGgfUAfyeXnPda8OLc9JU=";
    \\#   }};
    \\# }}
    \\# {{
    \\#   name = "mksv-0.0.1-SesxeIg4AAAxnAqrX4eSfBB-mFjYmbWpbgdfOWOZ2UU_";
    \\#   path = fetchzig {{
    \\#     url = "https://codeberg.org/mikastiv/mksv/archive/main.zip";
    \\#     hash = "sha256-ThaqFunjhGmi3XrJnF299GSGgfUAfyeXnPda8OLc9JU=";
    \\#   }};
    \\  }}
    \\]
;

const envrc =
    \\use flake
    \\
;

const gitignore =
    \\.zig-cache
    \\zig-out
    \\zig-pkg
    \\
;
