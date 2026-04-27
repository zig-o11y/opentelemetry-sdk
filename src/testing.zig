const std = @import("std");

/// Test scaffolding for tests that need a `std.Io` instance.
///
/// Usage:
///     var rt = TestRuntime.init(std.testing.allocator);
///     defer rt.deinit();
///     const io = rt.io();
///
/// This wraps `std.Io.Threaded` so individual tests don't have to repeat
/// the init/deinit boilerplate. Each `TestRuntime` owns its own thread pool.
pub const TestRuntime = struct {
    threaded: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator) TestRuntime {
        return .{ .threaded = std.Io.Threaded.init(allocator, .{}) };
    }

    pub fn deinit(self: *TestRuntime) void {
        self.threaded.deinit();
    }

    pub fn io(self: *TestRuntime) std.Io {
        return self.threaded.io();
    }
};
