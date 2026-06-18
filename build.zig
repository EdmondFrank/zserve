const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the executable
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "zserve",
        .root_module = root_module,
    });

    // Add nanoxml dependency for Office Open XML preview
    if (b.lazyDependency("nanoxml", .{
        .target = target,
        .optimize = optimize,
    })) |nanoxml| {
        root_module.addImport("nanoxml", nanoxml.module("nanoxml"));
    }

    // Add zpdf dependency for PDF preview
    if (b.lazyDependency("zpdf", .{
        .target = target,
        .optimize = optimize,
    })) |zpdf| {
        root_module.addImport("zpdf", zpdf.module("zpdf"));
    }

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // Test step - run all tests
    const test_step = b.step("test", "Run all unit tests");

    // Create modules for imports
    const url_module = b.createModule(.{
        .root_source_file = b.path("src/url.zig"),
        .target = target,
        .optimize = optimize,
    });

    const http_module = b.createModule(.{
        .root_source_file = b.path("src/http.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mime_types_module = b.createModule(.{
        .root_source_file = b.path("src/mime_types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // URL tests
    const test_url_module = b.createModule(.{
        .root_source_file = b.path("src/tests/test_url.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_url_module.addImport("url", url_module);
    const test_url = b.addTest(.{
        .name = "test_url",
        .root_module = test_url_module,
    });
    const run_test_url = b.addRunArtifact(test_url);
    test_step.dependOn(&run_test_url.step);

    // HTTP tests
    const test_http_module = b.createModule(.{
        .root_source_file = b.path("src/tests/test_http.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_http_module.addImport("http", http_module);
    const test_http = b.addTest(.{
        .name = "test_http",
        .root_module = test_http_module,
    });
    const run_test_http = b.addRunArtifact(test_http);
    test_step.dependOn(&run_test_http.step);

    // MIME types tests
    const test_mime_module = b.createModule(.{
        .root_source_file = b.path("src/tests/test_mime_types.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mime_module.addImport("mime_types", mime_types_module);
    const test_mime = b.addTest(.{
        .name = "test_mime",
        .root_module = test_mime_module,
    });
    const run_test_mime = b.addRunArtifact(test_mime);
    test_step.dependOn(&run_test_mime.step);
}
