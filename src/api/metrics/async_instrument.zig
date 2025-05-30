const std = @import("std");
const Kind = @import("instrument.zig").Kind;
const MeasurementsData = @import("measurement.zig").MeasurementsData;
const DataPoint = @import("measurement.zig").DataPoint;

/// An asynchronous instrument is a metric that reports measurements
/// when the metere is observed thourhg a callback.
pub const AsyncInstrument = @This();

pub const MetricObserveError = error{
    /// The callback failed to observe the measurements.
    CallbackExecutionFailed,
} || std.mem.Allocator.Error;

const ObserverContext = struct {
    /// The context in which the measurements were observed.
    /// This can be used to pass additional data to the callback.
    context: *anyopaque,
};

/// Defines the callback that can be used to observe measurements in Asynchronous Instruments.
/// The "context" parameter is used to pass any additional data needed for the observation.
/// Callers are expected to free up the memory for the returned MeasurementsData.
pub const ObserveMeasures = *const fn (context: ObserverContext, allocator: std.mem.Allocator) MetricObserveError!MeasurementsData;

/// Returns an instance of an asynchronous instrument by Kind.
/// The type parameter determines the type of the counter: unsigned integers produce an instrument of Kind .ObservableCounter,
/// signed integers produce an instrument of Kind .ObservableUpDownCounter.
pub fn ObservableInstrument(K: Kind) type {
    switch (K) {
        .ObservableCounter, .ObservableGauge, .ObservableUpDownCounter => {
            return struct {
                const Self = @This();

                allocator: std.mem.Allocator,
                kind: Kind = K,
                lock: std.Thread.Mutex = .{},
                /// List of functions that will produce data points when called.
                /// Functions are called by the Meter when it observes the instrument (e.g. when Metricreader collects metrics).
                callbacks: ?[]ObserveMeasures = null,

                pub fn init(allocator: std.mem.Allocator) Self {
                    return Self{
                        .allocator = allocator,
                    };
                }

                pub fn registerCallback(self: *Self, callback: ObserveMeasures) !void {
                    self.lock.lock();
                    defer self.lock.unlock();

                    if (self.callbacks) |c| {
                        var new_callbacks = try self.allocator.alloc(ObserveMeasures, c.len + 1);
                        std.mem.copyForwards(ObserveMeasures, new_callbacks, c);
                        new_callbacks[c.len] = callback;
                        self.callbacks = new_callbacks;
                        self.allocator.free(c);
                    } else {
                        self.callbacks = try self.allocator.alloc(ObserveMeasures, 1);
                        self.callbacks.?[0] = callback;
                    }
                }

                pub fn deinit(self: *Self) void {
                    if (self.callbacks) |c| self.allocator.free(c);
                }
            };
        },
        else => @compileError("Unsupported Kind for ObservableInstrument."),
    }
}

fn testCallback(_: ObserverContext, allocator: std.mem.Allocator) MetricObserveError!MeasurementsData {
    const data = try allocator.alloc(DataPoint(i64), 1);
    data[0] = try DataPoint(i64).new(allocator, 42, .{});
    return .{ .int = data };
}

test ObservableInstrument {
    const allocator = std.testing.allocator;
    const instrument = try allocator.create(ObservableInstrument(.ObservableUpDownCounter));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableUpDownCounter).init(allocator);
    defer instrument.deinit();

    try instrument.registerCallback(testCallback);
    try std.testing.expect(instrument.callbacks.?[0] == testCallback);
}
