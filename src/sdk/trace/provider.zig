const trace = @import("../../api/trace.zig");
/// TracerProvider is an OpenTelemetry TracerProvider.
/// That implements the TracerProvider interface.
pub const TracerProvider = struct {
    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    fn tracer(_: *Self, _: []const u8, _: ?trace.TracerConfig) trace.Tracer {
        // Get a pointer to the instance of the struct that implements the interface.
        // const self: *Self = @fieldParentPtr("provider", iface);
        return .{};
    }
};

test "TracerProvider succeeds to be initialized" {
    _ = TracerProvider.init();
}
