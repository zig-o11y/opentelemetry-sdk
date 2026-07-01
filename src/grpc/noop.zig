//! No-op gRPC transport. Selected by `-Dgrpc-provider=none` (the default).
//! Every call returns `error.UnimplementedTransportProtocol` so callers see a
//! clear failure rather than a silent drop when the SDK is built without a
//! real gRPC backend.

const std = @import("std");

pub const Configuration = @import("config.zig").Configuration;

pub fn send(
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: Configuration,
) error{UnimplementedTransportProtocol}!void {
    return error.UnimplementedTransportProtocol;
}

test "noop send always reports UnimplementedTransportProtocol" {
    try std.testing.expectError(
        error.UnimplementedTransportProtocol,
        send(std.testing.allocator, "/some/Service/Method", "payload", .{}),
    );
}

test {
    // Pull config tests into this module's test suite so they run regardless
    // of which gRPC backend is selected at build time.
    _ = @import("config.zig");
}
