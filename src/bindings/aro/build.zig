const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const aro_dep = b.dependency("aro", .{
        .target = target,
        .optimize = optimize,
    });

    // Static library (linked into native msc binary)
    const lib = b.addStaticLibrary(.{
        .name = "aro_ffi",
        .root_source_file = b.path("ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addImport("aro", aro_dep.module("aro"));
    lib.bundle_compiler_rt = true;

    b.installArtifact(lib);

    // Shared library (loaded by Bun via bun:ffi)
    const shared = b.addSharedLibrary(.{
        .name = "aro_ffi",
        .root_source_file = b.path("ffi.zig"),
        .target = target,
        .optimize = optimize,
    });

    shared.root_module.addImport("aro", aro_dep.module("aro"));
    shared.bundle_compiler_rt = true;

    b.installArtifact(shared);

    // Also install ARO's builtin C headers (needed at runtime for preprocessing)
    b.installDirectory(.{
        .source_dir = aro_dep.path("include"),
        .install_dir = .prefix,
        .install_subdir = "include",
    });
}
