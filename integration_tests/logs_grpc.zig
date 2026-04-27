//! Integration test for OTLP/gRPC logs export.
//!
//! Requires the SDK to be built with `-Dgrpc-provider=libgrpc`. With the
//! default (`none`) provider, the gRPC transport is the noop stub that
//! returns `UnimplementedTransportProtocol`, and this test will fail fast
//! with that error — which is the intended signal that you forgot the flag.
//!
//! Run with:
//!   zig build integration -Dgrpc-provider=libgrpc -- logs_grpc

const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const logs_sdk = sdk.logs;
const common = @import("common.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("memory leak detected");
    const allocator = gpa.allocator();

    var ctx = try common.setupTestContext(allocator, "logs-grpc");
    defer common.cleanupTestContext(&ctx);

    std.debug.print("Running logs gRPC integration test...\n", .{});
    try testLogsOverGrpc(allocator, ctx.tmp_dir);
    std.debug.print("✓ Logs gRPC test passed\n\n", .{});
}

fn testLogsOverGrpc(allocator: std.mem.Allocator, tmp_dir: std.fs.Dir) !void {
    var config = try sdk.otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    // Talk to the collector's gRPC port, in plaintext. We deliberately leave
    // `config.insecure` unset so the default credential-selection logic
    // applies: a localhost endpoint with no TLS material falls back to
    // LOCAL_TCP, which is plaintext but loopback-only — the exact path most
    // dev setups will hit.
    config.protocol = .grpc;
    config.endpoint = "localhost:" ++ common.COLLECTOR_GRPC_PORT;

    var otlp_exporter = try logs_sdk.OTLPExporter.init(allocator, config);
    defer otlp_exporter.deinit();
    const exporter = otlp_exporter.asLogRecordExporter();

    var simple_processor = logs_sdk.SimpleLogRecordProcessor.init(allocator, exporter);
    const processor = simple_processor.asLogRecordProcessor();

    const service_name: []const u8 = "integration-test-grpc";
    const resource_attrs = try sdk.Attributes.from(allocator, .{
        "service.name", service_name,
    });
    defer if (resource_attrs) |attrs| allocator.free(attrs);

    var provider = try logs_sdk.LoggerProvider.init(allocator, resource_attrs);
    defer provider.deinit();

    try provider.addLogRecordProcessor(processor);

    const scope = sdk.scope.InstrumentationScope{
        .name = "integration-test-grpc",
        .version = "1.0.0",
    };
    const logger = try provider.getLogger(scope);

    const num_logs = 5;
    logger.emit(1, "TRACE", "gRPC trace log", null);
    logger.emit(5, "DEBUG", "gRPC debug log", null);
    logger.emit(9, "INFO", "gRPC info log", null);
    logger.emit(13, "WARN", "gRPC warning log", null);
    logger.emit(17, "ERROR", "gRPC error log", null);

    const attrs = [_]sdk.attributes.Attribute{
        .{ .key = "transport", .value = .{ .string = "grpc" } },
        .{ .key = "test.iteration", .value = .{ .int = 1 } },
    };
    logger.emit(9, "INFO", "gRPC log with attributes", &attrs);

    try provider.shutdown();

    std.debug.print("  Sent {d} log records over gRPC\n", .{num_logs + 1});
    std.debug.print("  Waiting for logs JSON file...\n", .{});

    const json_content = common.waitForFileContent(allocator, tmp_dir, "logs.json", "gRPC info log", 15) catch |err| {
        if (err == error.ExpectedContentNotFound) {
            const stale_content = common.readJsonFile(allocator, tmp_dir, "logs.json") catch {
                std.debug.print("  ERROR: Could not read logs.json\n", .{});
                return error.LogsNotReceivedByCollector;
            };
            defer allocator.free(stale_content);
            std.debug.print("  ERROR: gRPC logs JSON doesn't contain expected data\n", .{});
            std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{stale_content[0..@min(stale_content.len, 500)]});
            return error.LogsNotReceivedByCollector;
        }
        return err;
    };
    defer allocator.free(json_content);

    const has_grpc_log = std.mem.indexOf(u8, json_content, "gRPC info log") != null;
    const has_resource_logs = std.mem.indexOf(u8, json_content, "resourceLogs") != null or
        std.mem.indexOf(u8, json_content, "resource_logs") != null;
    const has_service_name = std.mem.indexOf(u8, json_content, "integration-test-grpc") != null;
    const has_transport_attr = std.mem.indexOf(u8, json_content, "grpc") != null;

    if (!has_grpc_log or !has_resource_logs or !has_service_name) {
        std.debug.print("  ERROR: gRPC logs JSON doesn't contain expected data\n", .{});
        std.debug.print("  has_grpc_log={}, has_resource_logs={}, has_service_name={}\n", .{
            has_grpc_log, has_resource_logs, has_service_name,
        });
        std.debug.print("  JSON content sample (first 500 chars):\n{s}\n", .{json_content[0..@min(json_content.len, 500)]});
        return error.LogsNotReceivedByCollector;
    }

    std.debug.print("  ✓ gRPC logs JSON validated - found expected log records\n", .{});
    if (has_transport_attr) {
        std.debug.print("  ✓ Transport attribute 'grpc' present\n", .{});
    }
}
