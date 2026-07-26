const std = @import("std");

/// Single source of truth for `--version`; `tools/gen-npm.mjs` reads the same
/// number out of package.json, and the publish workflow refuses a mismatched tag.
const version = @import("build.zig.zon").version;

/// The platforms published to npm: what Zig targets reliably and npm can
/// express with os/cpu/libc.
const Platform = struct {
    suffix: []const u8,
    query: std.Target.Query,

    const all = [_]Platform{
        .{ .suffix = "linux-x64-gnu", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu } },
        .{ .suffix = "linux-x64-musl", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
        .{ .suffix = "linux-arm64-gnu", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu } },
        .{ .suffix = "linux-arm64-musl", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
        .{ .suffix = "darwin-x64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .suffix = "darwin-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .suffix = "win32-x64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
        .{ .suffix = "win32-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .windows } },
        .{ .suffix = "freebsd-x64", .query = .{ .cpu_arch = .x86_64, .os_tag = .freebsd } },
    };
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = addZcov(b, target, optimize);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run zcov").dependOn(&run.step);

    // Cross-compile every published platform into npm/zcov-<suffix>/. Binaries
    // only: tools/gen-npm.mjs writes the package.json files.
    const release = b.step("release", "Cross-compile every published platform into npm/");
    for (Platform.all) |p| {
        const cross = addZcov(b, b.resolveTargetQuery(p.query), .ReleaseFast);
        const install = b.addInstallArtifact(cross, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("../npm/zcov-{s}", .{p.suffix}) } },
        });
        release.dependOn(&install.step);
    }
}

fn addZcov(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const yuku = b.dependency("yuku", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "zcov",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", opts);
    exe.root_module.addImport("parser", yuku.module("parser"));
    return exe;
}
