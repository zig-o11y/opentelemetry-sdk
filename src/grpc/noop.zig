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
