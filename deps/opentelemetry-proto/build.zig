const std = @import("std");
const protobuf = @import("protobuf");

const BuildError = error{
    MissingTag,
};

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Protobuf code generation from the OpenTelemetry proto files.
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    var protoc_step = protobuf.RunProtocStep.create(protobuf_dep.builder, target, .{
        // Output directory for the generated zig files
        .destination_directory = b.path("src"),
        .source_files = &.{
            // Add more protobuf definitions as the API grows
            // Signals
            "proto-src/opentelemetry/proto/common/v1/common.proto",
            "proto-src/opentelemetry/proto/resource/v1/resource.proto",
            "proto-src/opentelemetry/proto/metrics/v1/metrics.proto",
            "proto-src/opentelemetry/proto/trace/v1/trace.proto",
            "proto-src/opentelemetry/proto/logs/v1/logs.proto",
            "proto-src/opentelemetry/proto/profiles/v1development/profiles.proto",
            // collector types for OTLP
            "proto-src/opentelemetry/proto/collector/metrics/v1/metrics_service.proto",
            "proto-src/opentelemetry/proto/collector/trace/v1/trace_service.proto",
            "proto-src/opentelemetry/proto/collector/logs/v1/logs_service.proto",
            "proto-src/opentelemetry/proto/collector/profiles/v1development/profiles_service.proto",
        },
        .include_directories = &.{
            // Imports in proto files require that the top-level directory
            // containing te proto files is included
            "proto-src/",
        },
    });

    // Debug protoc generation in Debug builds
    protoc_step.verbose = optimize == .Debug;

    b.getInstallStep().dependOn(&protoc_step.step);

    const lib_mod = b.addModule("opentelemetry-proto", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf_dep.module("protobuf") },
        },
    });

    const lib = b.addLibrary(.{
        .name = "opentelemetry-proto",
        .root_module = lib_mod,
    });
    const lib_install = b.addInstallArtifact(lib, .{});

    b.getInstallStep().dependOn(&lib.step);
    b.getInstallStep().dependOn(&lib_install.step);

    const tag = b.option([]const u8, "tag",
        \\The tag to use for the OpenTelemetry proto submodule.
        \\If not set, the latest commit will be used.
    );

    const update_remote = b.addSystemCommand(&.{
        "git",
        "submodule",
        "update",
        "--remote",
    });
    const update_to_tag = b.addSystemCommand(&.{
        "git",
        "submodule",
        "foreach",
        try std.fmt.allocPrint(b.allocator, "git checkout {s}", .{tag orelse ""}),
    });
    update_to_tag.step.dependOn(&update_remote.step);

    const update_step = b.step("update-tag", "Update OpenTelemetry proto submodule to the specified tag");
    update_step.dependOn(&update_to_tag.step);

    if (tag) |t| {
        // we need to remove the initial "v" from the tag to mirror the versioning scheme used in the `build.zig.zon` file.
        const semantic_version = if (std.mem.startsWith(u8, t, "v")) t[1..] else t;
        const versioning_step = VersioningStep.init(b, semantic_version);
        update_step.dependOn(&versioning_step.step);
    }
}

const VersioningStep = struct {
    const Self = @This();

    upgrade_to: []const u8,
    step: std.Build.Step,

    pub fn init(parent: *std.Build, upgrade_to: []const u8) *Self {
        const self = parent.allocator.create(Self) catch @panic("OOM");
        self.* = Self{
            .step = std.Build.Step.init(.{
                .owner = parent,
                .id = .write_file,
                .name = "update zig zon",
                .makeFn = make,
            }),
            .upgrade_to = upgrade_to,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const b = step.owner;
        const self: *VersioningStep = @fieldParentPtr("step", step);

        try replaceVersionInZigZonFile(b, self.upgrade_to);
    }
};

test "replace version in build.zig.zon" {
    const sample =
        \\.{
        \\  .name = .opentelemetry_proto,
        \\  .version = "1.2.3",
        \\  .fingerprint = aaabbbcccddd,
        \\  .minimum_zig_version = "0.15.1",
        \\  .dependencies = &.{};
        \\  .paths = &.{},
        \\}
    ;

    // Replace the content of the .version field with a new version)
    const new_version = "3.2.1";
    const output = try std.testing.allocator.alloc(u8, sample.len);
    defer std.testing.allocator.free(output);

    _ = std.mem.replace(u8, sample, "1.2.3", new_version, output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, new_version));
}

test "replace version in file" {
    const sample =
        \\.{
        \\    .name = .opentelemetry_proto,
        \\    .version = "1.2.3",
        \\    .fingerprint = aaabbbcccddd,
        \\    .minimum_zig_version = "0.15.1",
        \\    .dependencies = &.{};
        \\    .paths = &.{},
        \\}
    ;

    const new_version = "3.2.1";
    var temp_dir = std.testing.tmpDir(.{ .access_sub_paths = true });
    defer temp_dir.cleanup();

    try temp_dir.dir.writeFile(.{
        .data = sample,
        .sub_path = "zon",
        .flags = .{ .read = true },
    });

    const zon = try temp_dir.dir.openFile(
        "zon",
        .{ .mode = .read_write, .lock = .exclusive },
    );

    defer zon.close(std.Options.debug_io);
    var read_buf: [1024]u8 = undefined;
    var reader = zon.reader(std.Options.debug_io, &read_buf);

    var output: std.ArrayList(u8) = try .initCapacity(std.testing.allocator, sample.len);
    defer output.deinit(std.testing.allocator);

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch break;
        if (std.mem.indexOf(u8, line, ".version")) |_| {
            const new_line = try std.fmt.allocPrint(std.testing.allocator, "    .version = \"{s}\",\n", .{new_version});
            defer std.testing.allocator.free(new_line);

            try output.appendSlice(std.testing.allocator, new_line);
        } else {
            try output.appendSlice(std.testing.allocator, line);
        }
    }
    var write_buf: [1024]u8 = undefined;
    var writer = zon.writer(std.Options.debug_io, &write_buf);
    try writer.interface.writeAll(output.items);
    try writer.interface.flush();

    const after_update =
        \\.{
        \\    .name = .opentelemetry_proto,
        \\    .version = "3.2.1",
        \\    .fingerprint = aaabbbcccddd,
        \\    .minimum_zig_version = "0.15.1",
        \\    .dependencies = &.{};
        \\    .paths = &.{},
        \\}
    ;

    var update_buf: [1024]u8 = undefined;
    const updated_content = try temp_dir.dir.readFile("zon", &update_buf);
    try std.testing.expectEqualStrings(after_update, updated_content);
}

fn replaceVersionInZigZonFile(b: *std.Build, new_version: []const u8) !void {
    const zon_path = b.path(".");

    const zon = try zon_path.getPath3(b, null).openFile(
        std.Options.debug_io,
        "build.zig.zon",
        .{ .mode = .read_write, .lock = .exclusive },
    );
    defer zon.close(std.Options.debug_io);

    var read_buf: [1024]u8 = undefined;
    var reader = zon.reader(std.Options.debug_io, &read_buf);

    var output: std.ArrayList(u8) = try .initCapacity(b.allocator, 1024);
    defer output.deinit(b.allocator);

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch break;
        if (std.mem.indexOf(u8, line, ".version")) |_| {
            const new_line = try std.fmt.allocPrint(b.allocator, "    .version = \"{s}\",\n", .{new_version});
            defer b.allocator.free(new_line);

            try output.appendSlice(b.allocator, new_line);
        } else {
            try output.appendSlice(b.allocator, line);
        }
    }
    var write_buf: [1024]u8 = undefined;
    var writer = zon.writer(std.Options.debug_io, &write_buf);
    try writer.interface.writeAll(output.items);
    try writer.interface.flush();
}
