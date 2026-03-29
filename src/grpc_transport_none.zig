const std = @import("std");

pub fn send(
    _: std.mem.Allocator,
    _: []const u8,
    _: u64,
    _: []const u8,
    _: []const u8,
) error{UnimplementedTransportProtocol}!void {
    return error.UnimplementedTransportProtocol;
}
