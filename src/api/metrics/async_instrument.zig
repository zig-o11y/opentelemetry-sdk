const std = @import("std");
const Kind = @import("instrument.zig").Kind;
const MeasurementsData = @import("measurement.zig").MeasurementsData;
const DataPoint = @import("measurement.zig").DataPoint;

const Attributes = @import("../../attributes.zig").Attributes;

/// An asynchronous instrument is a metric that reports measurements
/// when the metere is observed thourhg a callback.
pub const AsyncInstrument = @This();

/// Errors that can occur while observing measurements,
pub const MetricObserveError = error{
    /// The callback failed to observe the measurements.
    CallbackExecutionFailed,
    /// The callback returned a collection of data points whose type is not supported by the instrument.
    UnsupportedDataPointTypeReturnedByCallback,
    /// Two separate callbacks returned distinct collection of data points with different types.
    NonUniformMeasurementsDataType,
} || std.mem.Allocator.Error;

const ObservedContext = struct {
    /// The context in which the measurements were observed.
    /// This can be used to pass additional data to the callback.
    context: ?*anyopaque = null,
};

/// Defines the callback that can be used to observe measurements in Asynchronous Instruments.
/// The "context" parameter is used to pass any additional data needed for the observation.
/// Callers are expected to free up the memory for the returned MeasurementsData.
pub const ObserveMeasures = *const fn (context: ObservedContext, allocator: std.mem.Allocator) MetricObserveError!MeasurementsData;

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

                pub fn deinit(self: *Self) void {
                    if (self.callbacks) |c| self.allocator.free(c);
                }

                /// Attaches a callback to the instrument.
                /// Of separate callbacks produce data points with equal attributes, only the last
                /// observation is kept, using the order of registration.
                /// All callbacks are expected to return a MeasurementsData with consistent type.
                /// If different callbacks return different types, an error is returned when observing them.
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

                fn observe(self: *Self, ctx: ObservedContext, allocator: std.mem.Allocator) MetricObserveError!?MeasurementsData {
                    self.lock.lock();
                    defer self.lock.unlock();

                    if (self.callbacks) |c| {
                        var m = try allocator.alloc(MeasurementsData, c.len);
                        defer allocator.free(m);

                        for (c, 0..) |callback, idx| {
                            const result = try callback(ctx, allocator);
                            // We need to ensure that all callbacks return the same type of data points.
                            if (idx > 0) {
                                if (std.meta.activeTag(result) != std.meta.activeTag(m[idx - 1])) {
                                    return MetricObserveError.NonUniformMeasurementsDataType;
                                }
                            }
                            switch (result) {
                                .int, .double => {},
                                else => return MetricObserveError.UnsupportedDataPointTypeReturnedByCallback,
                            }
                            m[idx] = result;
                        }

                        // Join all data points from the callbacks into a single MeasurementsData.
                        // We need to find first the type of data points we are dealing with.
                        var uniqueData: MeasurementsData = m[0];
                        if (m.len > 1) {
                            for (1..m.len) |i| {
                                try uniqueData.join(m[i], allocator);
                            }
                        }

                        // De-duplicate data points with the same attributes.
                        try uniqueData.dedupByAttributes(allocator);

                        return uniqueData;
                    }
                    return null; // No callbacks registered, nothing to observe.
                }

                /// Observes the instrument and returns the measurements collected by the callbacks.
                /// Data points with the same attributes are de-duplicated keeping only the last one,
                /// by the order of callbacks registration.
                pub fn measurementsData(self: *Self, allocator: std.mem.Allocator) !MeasurementsData {
                    return try self.observe(.{}, allocator) orelse MeasurementsData{ .int = &.{} };
                }
            };
        },
        else => @compileError("Unsupported Kind for ObservableInstrument."),
    }
}

fn testCallback(_: ObservedContext, allocator: std.mem.Allocator) MetricObserveError!MeasurementsData {
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

test "observable instrument with multiple callbacks" {
    const anotherCallback: ObserveMeasures = testCallback;

    const allocator = std.testing.allocator;
    const instrument = try allocator.create(ObservableInstrument(.ObservableGauge));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableGauge).init(allocator);
    defer instrument.deinit();

    try instrument.registerCallback(testCallback);
    try instrument.registerCallback(anotherCallback);

    try std.testing.expect(instrument.callbacks.?[0] == testCallback);
    try std.testing.expect(instrument.callbacks.?[1] == anotherCallback);
}

fn testCallbackWithAttrs(_: ObservedContext, allocator: std.mem.Allocator) MetricObserveError!MeasurementsData {
    const data = try allocator.alloc(DataPoint(f64), 1);
    data[0] = try DataPoint(f64).new(allocator, 3.14, .{ "pi", true });
    return .{ .double = data };
}

test "observable instrument collects data" {
    const allocator = std.testing.allocator;
    const instrument = try allocator.create(ObservableInstrument(.ObservableCounter));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableCounter).init(allocator);
    defer instrument.deinit();

    try instrument.registerCallback(testCallbackWithAttrs);
    try instrument.registerCallback(testCallbackWithAttrs);

    // We expect the data to be de-duplicated, so we should only have one data point.
    const data = try instrument.observe(.{}, allocator);
    defer {
        for (data.?.double) |*dp| dp.deinit(allocator);
        allocator.free(data.?.double);
    }
    // Only one data point should be returned, as both callbacks return the same data.
    try std.testing.expectEqual(1, data.?.double.len);
}

test "observable instrument fails to observe callbacks with different data types" {}

test "observable instrument with context passed from observe to callbacks" {}

// The specification says:
// "Callback functions SHOULD NOT make duplicate observations (more than one Measurement with the same attributes) across all registered callbacks."
// Hence, we need to ensure that the observable instrument does not fetch duplicate data from multiple callbacks.
test "observable instrument de-duplicate datapoints when fetching" {
    const allocator = std.testing.allocator;
    const instrument = try allocator.create(ObservableInstrument(.ObservableGauge));
    defer allocator.destroy(instrument);

    instrument.* = ObservableInstrument(.ObservableGauge).init(allocator);
    defer instrument.deinit();

    try instrument.registerCallback(testCallbackWithAttrs);
    try instrument.registerCallback(testCallbackWithAttrs);

    // We expect the data to be de-duplicated, so we should only have one data point.
    const data = try instrument.measurementsData(allocator);
    defer allocator.free(data.double);
    defer for (data.double) |*dp| dp.deinit(allocator);

    try std.testing.expectEqual(1, data.double.len);
}
