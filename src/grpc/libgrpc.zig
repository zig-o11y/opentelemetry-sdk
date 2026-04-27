const std = @import("std");
const grpc = @import("cgrpc_wrapper");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.grpc_transport);

pub const Configuration = @import("config.zig").Configuration;

/// Send a pre-encoded protobuf payload to a gRPC endpoint.
///
/// `path` is the gRPC method path, e.g. "/package.Service/Method".
/// `data` is the raw protobuf-encoded request body.
pub fn send(
    gpa: Allocator,
    path: []const u8,
    data: []const u8,
    config: Configuration,
) !void {
    // TODO: do it once globally
    grpc.init();
    defer grpc.deinit();

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const endpoint: [:0]u8 = try arena.dupeZ(u8, config.endpoint);

    var credentials: grpc.client.Credentials = try makeCredentials(arena, config);
    defer credentials.deinit();

    var channel: grpc.Channel = try grpc.Channel.init(endpoint, credentials);
    defer channel.deinit();

    var queue: grpc.PluckQueue = .init();
    defer queue.deinit();
    defer queue.shutdown();

    const deadline: grpc.Deadline = .{ .duration = @as(i128, config.timeout_sec) * std.time.ns_per_s };
    switch (try grpc.client.rawUnaryCall(gpa, &channel, &queue, path, data, deadline)) {
        .success => |bytes| if (bytes) |b| gpa.free(b),
        .failure => |f| {
            defer gpa.free(f.details);
            log.err("gRPC error {}: {s}", .{ f.code, f.details });
            return switch (f.toZigError()) {
                // Retryable: server temporarily unavailable or rate-limited.
                error.Unavailable, error.ResourceExhausted => error.RequestEnqueuedForRetry,
                else => error.NonRetryableStatusCodeInResponse,
            };
        },
        .operation_failed => {
            log.err("gRPC batch operation failed (no status available)", .{});
            return error.NonRetryableStatusCodeInResponse;
        },
        .timeout => return error.Timeout,
    }
}

fn makeCredentials(arena: Allocator, config: Configuration) !grpc.client.Credentials {
    if (config.insecure) |insecure| {
        if (insecure) {
            log.debug("Selecting insecure credentials", .{});
            return .insecure();
        }
        return makeSSLCredentials(arena, config);
    }
    if (std.mem.startsWith(u8, config.endpoint, "localhost:")) {
        log.debug("Selecting local TCP credentials", .{});
        return .localTCP();
    }
    return makeSSLCredentials(arena, config);
}

inline fn readFile(allocator: Allocator, filename: []const u8) ![:0]u8 {
    const max_size: usize = 1 << 20; // 1MiB

    return std.fs.cwd().readFileAllocOptions(
        allocator,
        filename,
        max_size,
        null,
        .of(u8),
        0,
    );
}

/// An arena is required as it will leak the files content
fn makeSSLCredentials(arena: Allocator, config: Configuration) !grpc.client.Credentials {
    var root_certs: ?[:0]u8 = null;
    var client_key_cert: ?*grpc.SSLKeyCertPair = null;

    if (config.server_root_certificates_filename) |filename|
        root_certs = try readFile(arena, filename);
    if (config.client_certificate_filename) |cert_filename| {
        if (config.client_private_key_filename) |key_filename| {
            client_key_cert = try arena.create(grpc.SSLKeyCertPair);
            client_key_cert.?.private_key = try readFile(arena, key_filename);
            client_key_cert.?.certificate_chain = try readFile(arena, cert_filename);
        }
    }
    log.debug("Selecting SSL credentials {s}, {s} a provided client key/certificate", .{
        if (root_certs != null) "with a provided server root certificates" else "using server root certificates in GRPC_DEFAULT_SSL_ROOTS_FILE_PATH or in system directories",
        if (client_key_cert != null) "with" else "without",
    });
    return .ssl(root_certs, client_key_cert);
}
