// OpenTelemetry SDK implementation for Zig.

// Test SDK implementations
test {
    _ = @import("sdk/trace.zig");
    _ = @import("metrics/metrics.zig");
    // helpers
    _ = @import("pbutils.zig");
}
