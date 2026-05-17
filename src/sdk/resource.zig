const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");
const Attribute = @import("../attributes.zig").Attribute;
const AttributeValue = @import("../attributes.zig").AttributeValue;
const Configuration = @import("config.zig").Configuration;

const os_type: []const u8 = switch (builtin.os.tag) {
    .linux => "linux",
    .macos, .ios, .tvos, .watchos => "darwin",
    .windows => "windows",
    .freebsd => "freebsd",
    .netbsd => "netbsd",
    .openbsd => "openbsd",
    .dragonfly => "dragonflybsd",
    .illumos => "solaris",
    else => @tagName(builtin.os.tag),
};

const host_arch: []const u8 = switch (builtin.cpu.arch) {
    .x86_64 => "amd64",
    .aarch64 => "arm64",
    .arm => "arm32",
    .x86 => "x86",
    .powerpc => "ppc32",
    .powerpc64, .powerpc64le => "ppc64",
    .s390x => "s390x",
    else => @tagName(builtin.cpu.arch),
};

/// SDK identity attributes, always added when the SDK is active.
const sdk_attributes = [_]Attribute{
    .{ .key = "telemetry.sdk.name", .value = .{ .string = build_info.name } },
    .{ .key = "telemetry.sdk.language", .value = .{ .string = "zig" } },
    .{ .key = "telemetry.sdk.version", .value = .{ .string = build_info.version } },
};

/// Attributes provided by the "os" detector (OTEL_EXPERIMENTAL_RESOURCE_DETECTORS=os).
const os_attributes = [_]Attribute{
    .{ .key = "os.type", .value = .{ .string = os_type } },
};

/// Attributes provided by the "host" detector (OTEL_EXPERIMENTAL_RESOURCE_DETECTORS=host).
const host_attributes = [_]Attribute{
    .{ .key = "host.arch", .value = .{ .string = host_arch } },
};

/// Attributes provided by the "process" detector (OTEL_EXPERIMENTAL_RESOURCE_DETECTORS=process).
const process_attributes = [_]Attribute{
    .{ .key = "process.runtime.name", .value = .{ .string = "zig" } },
    .{ .key = "process.runtime.version", .value = .{ .string = builtin.zig_version_string } },
};

/// Build resource attributes from configuration
/// Combines OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES
pub fn buildFromConfig(allocator: std.mem.Allocator, config: *const Configuration) ![]Attribute {
    const d = config.resource_detectors;
    const extra = (if (d.os) os_attributes.len else 0) +
        (if (d.host) host_attributes.len else 0) +
        (if (d.process) process_attributes.len else 0);
    var attributes: std.ArrayList(Attribute) = try .initCapacity(allocator, sdk_attributes.len + extra);
    errdefer {
        for (attributes.items) |attr| {
            allocator.free(attr.key);
            if (attr.value == .string) {
                allocator.free(attr.value.string);
            }
        }
        attributes.deinit(allocator);
    }

    for (sdk_attributes) |attr| {
        attributes.appendAssumeCapacity(try Attribute.dupe(allocator, attr));
    }
    if (d.os) for (os_attributes) |attr| {
        attributes.appendAssumeCapacity(try Attribute.dupe(allocator, attr));
    };
    if (d.host) for (host_attributes) |attr| {
        attributes.appendAssumeCapacity(try Attribute.dupe(allocator, attr));
    };
    if (d.process) for (process_attributes) |attr| {
        attributes.appendAssumeCapacity(try Attribute.dupe(allocator, attr));
    };

    // Add service.name if configured
    const has_service_name = config.service_name != null;
    if (config.service_name) |service_name| {
        try attributes.append(allocator, try Attribute.dupe(allocator, .{
            .key = "service.name",
            .value = .{ .string = service_name },
        }));
    }

    // Parse and add resource attributes
    // Skip service.name from resource_attributes if OTEL_SERVICE_NAME is set (it takes precedence)
    if (config.resource_attributes) |resource_attrs| {
        try parseResourceAttributes(allocator, resource_attrs, &attributes, has_service_name);
    }

    return try attributes.toOwnedSlice(allocator);
}

/// Parse resource attributes from comma-separated key=value pairs
/// Format: "key1=value1,key2=value2"
/// If skip_service_name is true, service.name entries will be skipped (OTEL_SERVICE_NAME takes precedence)
fn parseResourceAttributes(
    allocator: std.mem.Allocator,
    attrs_str: []const u8,
    attributes: *std.ArrayList(Attribute),
    skip_service_name: bool,
) !void {
    var iter = std.mem.splitScalar(u8, attrs_str, ',');
    while (iter.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Split on '=' to get key and value
        const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse {
            std.log.warn("Invalid resource attribute (missing '='): {s}", .{trimmed});
            continue;
        };

        const key_part = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
        const value_part = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

        if (key_part.len == 0) {
            std.log.warn("Invalid resource attribute (empty key): {s}", .{trimmed});
            continue;
        }

        // Skip service.name if OTEL_SERVICE_NAME is set (it takes precedence)
        if (skip_service_name and std.mem.eql(u8, key_part, "service.name")) {
            continue;
        }

        try attributes.append(allocator, try Attribute.dupe(allocator, .{
            .key = key_part,
            .value = .{ .string = value_part },
        }));
    }
}

/// Free resource attributes
pub fn freeResource(allocator: std.mem.Allocator, resource: []const Attribute) void {
    for (resource) |attr| {
        allocator.free(attr.key);
        if (attr.value == .string) {
            allocator.free(attr.value.string);
        }
    }
    allocator.free(resource);
}

/// Merge two resource attribute slices into a new one.
/// Caller is responsible for freeing the returned slice.
pub fn mergeResources(
    allocator: std.mem.Allocator,
    res1: []const Attribute,
    res2: []const Attribute,
) !?[]Attribute {
    var merged: std.ArrayList(Attribute) = try .initCapacity(allocator, res1.len + res2.len);
    errdefer merged.deinit(allocator);

    for (res1) |attr| {
        merged.appendAssumeCapacity(try Attribute.dupe(allocator, attr));
    }
    for (res2) |attr| {
        merged.appendAssumeCapacity(try Attribute.dupe(allocator, attr));
    }
    if (merged.items.len > 0) return try merged.toOwnedSlice(allocator) else return null;
}

test "buildFromConfig with service name only" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .resource_detectors = .{},
        .service_name = "my-service",
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(@as(usize, 4), resource.len);
    try std.testing.expectEqualStrings("service.name", resource[3].key);
    try std.testing.expectEqualStrings("my-service", resource[3].value.string);
}

test "buildFromConfig with resource attributes only" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .resource_detectors = .{},
        .service_name = null,
        .resource_attributes = "key1=value1,key2=value2",
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(@as(usize, 5), resource.len);
    try std.testing.expectEqualStrings("key1", resource[3].key);
    try std.testing.expectEqualStrings("value1", resource[3].value.string);
    try std.testing.expectEqualStrings("key2", resource[4].key);
    try std.testing.expectEqualStrings("value2", resource[4].value.string);
}

test "buildFromConfig with both service name and resource attributes" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .resource_detectors = .{},
        .service_name = "test-service",
        .resource_attributes = "deployment.environment=production,host.name=server-1",
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(@as(usize, 6), resource.len);
    try std.testing.expectEqualStrings("service.name", resource[3].key);
    try std.testing.expectEqualStrings("test-service", resource[3].value.string);
    try std.testing.expectEqualStrings("deployment.environment", resource[4].key);
    try std.testing.expectEqualStrings("production", resource[4].value.string);
    try std.testing.expectEqualStrings("host.name", resource[5].key);
    try std.testing.expectEqualStrings("server-1", resource[5].value.string);
}

test "parseResourceAttributes with whitespace and empty values" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .resource_detectors = .{},
        .service_name = null,
        .resource_attributes = " key1 = value1 , key2=value2,  ,key3=",
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    // Should parse 3 valid attributes (key3 has empty value which is valid)
    try std.testing.expectEqual(@as(usize, 6), resource.len);
    try std.testing.expectEqualStrings("key1", resource[3].key);
    try std.testing.expectEqualStrings("value1", resource[3].value.string);
    try std.testing.expectEqualStrings("key2", resource[4].key);
    try std.testing.expectEqualStrings("value2", resource[4].value.string);
    try std.testing.expectEqualStrings("key3", resource[5].key);
    try std.testing.expectEqualStrings("", resource[5].value.string);
}

test "buildFromConfig with no resource configuration" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .resource_detectors = .{},
        .service_name = null,
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(sdk_attributes.len, resource.len);
    try std.testing.expectEqualStrings("telemetry.sdk.name", resource[0].key);
    try std.testing.expectEqualStrings("opentelemetry", resource[0].value.string);
    try std.testing.expectEqualStrings("telemetry.sdk.language", resource[1].key);
    try std.testing.expectEqualStrings("zig", resource[1].value.string);
    try std.testing.expectEqualStrings("telemetry.sdk.version", resource[2].key);
}

test "buildFromConfig with all resource detectors enabled" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .resource_detectors = .{ .host = true, .os = true, .process = true },
        .service_name = null,
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    const expected_len = sdk_attributes.len + os_attributes.len + host_attributes.len + process_attributes.len;
    try std.testing.expectEqual(expected_len, resource.len);
    try std.testing.expectEqualStrings("os.type", resource[3].key);
    try std.testing.expectEqualStrings("host.arch", resource[4].key);
    try std.testing.expectEqualStrings("process.runtime.name", resource[5].key);
    try std.testing.expectEqualStrings("zig", resource[5].value.string);
    try std.testing.expectEqualStrings("process.runtime.version", resource[6].key);
    try std.testing.expectEqualStrings(builtin.zig_version_string, resource[6].value.string);
}

test "buildFromConfig with individual resource detectors" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .resource_detectors = .{ .os = true },
        .service_name = null,
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(sdk_attributes.len + os_attributes.len, resource.len);
    try std.testing.expectEqualStrings("os.type", resource[3].key);
}

test "OTEL_SERVICE_NAME overrides service.name from OTEL_RESOURCE_ATTRIBUTES" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .resource_detectors = .{},
        .service_name = "override-service",
        .resource_attributes = "service.name=original-service,key1=value1",
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(@as(usize, 5), resource.len);

    // service.name should be from OTEL_SERVICE_NAME
    try std.testing.expectEqualStrings("service.name", resource[3].key);
    try std.testing.expectEqualStrings("override-service", resource[3].value.string);

    // key1 should be from OTEL_RESOURCE_ATTRIBUTES
    try std.testing.expectEqualStrings("key1", resource[4].key);
    try std.testing.expectEqualStrings("value1", resource[4].value.string);
}

test "service.name from OTEL_RESOURCE_ATTRIBUTES when OTEL_SERVICE_NAME not set" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .resource_detectors = .{},
        .service_name = null,
        .resource_attributes = "service.name=from-resource-attrs,key1=value1",
        .log_level = .info,
        .trace_propagators = &.{},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    const resource = try buildFromConfig(allocator, &config);
    defer freeResource(allocator, resource);

    try std.testing.expectEqual(@as(usize, 5), resource.len);

    // service.name should be from OTEL_RESOURCE_ATTRIBUTES
    try std.testing.expectEqualStrings("service.name", resource[3].key);
    try std.testing.expectEqualStrings("from-resource-attrs", resource[3].value.string);

    try std.testing.expectEqualStrings("key1", resource[4].key);
    try std.testing.expectEqualStrings("value1", resource[4].value.string);
}
