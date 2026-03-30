const std = @import("std");
const grpc = @import("cgrpc_wrapper");
const otlp = @import("otlp.zig");

const log = std.log.scoped(.grpc_transport);

/// Send a pre-encoded protobuf payload to a gRPC endpoint.
///
/// `endpoint` is a "host:port" string.
/// `timeout_sec` is the maximum duration to wait for a response.
/// `path` is the gRPC method path, e.g. "/package.Service/Method".
/// `data` is the raw protobuf-encoded request body.
pub fn send(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    timeout_sec: u64,
    path: []const u8,
    data: []const u8,
) !void {
    grpc.init();
    defer grpc.deinit();

    const endpoint_z = try allocator.dupeZ(u8, endpoint);
    defer allocator.free(endpoint_z);

    var channel = try grpc.Channel.initInsecure(endpoint_z);
    defer channel.deinit();

    var queue: grpc.PluckQueue = .init();
    defer queue.deinit();
    defer queue.shutdown();

    const deadline: grpc.Deadline = .{ .duration = @as(i128, timeout_sec) * std.time.ns_per_s };
    switch (try grpc.client.rawUnaryCall(allocator, &channel, &queue, path, data, deadline)) {
        .success => |bytes| if (bytes) |b| allocator.free(b),
        .grpc_error => |e| {
            defer allocator.free(e.details);
            log.err("gRPC error {}: {s}", .{ e.code, e.details });
            return switch (e.code) {
                // Retryable: server temporarily unavailable or rate-limited.
                grpc.c.GRPC_STATUS_UNAVAILABLE,
                grpc.c.GRPC_STATUS_RESOURCE_EXHAUSTED,
                => otlp.ExportError.RequestEnqueuedForRetry,
                else => otlp.ExportError.NonRetryableStatusCodeInResponse,
            };
        },
        .operation_failed => {
            log.err("gRPC batch operation failed (no status available)", .{});
            return otlp.ExportError.NonRetryableStatusCodeInResponse;
        },
        .timeout => return error.Timeout,
    }
}
