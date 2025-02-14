const std = @import("std");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbcommon = @import("../../opentelemetry/proto/common/v1.pb.zig");
const pbresource = @import("../../opentelemetry/proto/resource/v1.pb.zig");
const pbmetrics = @import("../../opentelemetry/proto/metrics/v1.pb.zig");
const pbutils = @import("../../pbutils.zig");
const instr = @import("../../api/metrics/instrument.zig");
const Instrument = instr.Instrument;
const Kind = instr.Kind;
const MeterProvider = @import("../../api/metrics/meter.zig").MeterProvider;
const Attribute = @import("../../attributes.zig").Attribute;
const view = @import("view.zig");
const exporter = @import("exporter.zig");
const MetricExporter = exporter.MetricExporter;
const Exporter = exporter.ExporterIface;
const ExportResult = exporter.ExportResult;
const InMemoryExporter = exporter.ImMemoryExporter;

/// ExportError represents the failure to export data points
/// to a destination.
pub const MetricReadError = error{
    CollectFailedOnMissingMeterProvider,
    ExportFailed,
    ForceFlushTimedOut,
};

/// MetricReader reads metrics' data from a MeterProvider.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#metricreader
pub const MetricReader = struct {
    allocator: std.mem.Allocator,
    // Exporter is the destination of the metrics data.
    // MetricReader takes oenwrship of the exporter.
    exporter: *MetricExporter = undefined,
    // We can read the instruments' data points from the meters
    // stored in meterProvider.
    meterProvider: ?*MeterProvider = null,

    temporality: *const fn (Kind) view.Temporality = view.DefaultTemporalityFor,
    aggregation: *const fn (Kind) view.Aggregation = view.DefaultAggregationFor,
    // Signal that shutdown has been called.
    hasShutDown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, metricExporter: *MetricExporter) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .exporter = metricExporter,
        };
        return s;
    }

    pub fn withTemporality(self: *Self, temporality: *const fn (Kind) view.Temporality) *Self {
        self.temporality = temporality;
        return self;
    }

    pub fn withAggregation(self: *Self, aggregation: *const fn (Kind) view.Aggregation) *Self {
        self.aggregation = aggregation;
        return self;
    }

    pub fn collect(self: *Self) !void {
        if (self.hasShutDown.load(.acquire)) {
            // When shutdown has already been called, collect is a no-op.
            return;
        }
        var metricsData = pbmetrics.MetricsData{ .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).init(self.allocator) };
        defer metricsData.deinit();

        if (self.meterProvider) |mp| {
            // Collect the data from each meter provider.
            var mpIter = mp.meters.valueIterator();
            while (mpIter.next()) |meter| {
                // Create a resourceMetric for each Meter.
                const attrs = try attributesToProtobufKeyValueList(self.allocator, meter.attributes);
                var rm = pbmetrics.ResourceMetrics{
                    .resource = pbresource.Resource{ .attributes = attrs.values },
                    .scope_metrics = std.ArrayList(pbmetrics.ScopeMetrics).init(self.allocator),
                };
                // We only use a single ScopeMetric for each ResourceMetric.
                var sm = pbmetrics.ScopeMetrics{
                    .metrics = std.ArrayList(pbmetrics.Metric).init(self.allocator),
                };
                var instrIter = meter.instruments.valueIterator();
                while (instrIter.next()) |i| {
                    if (toProtobufMetric(self.allocator, self.temporality, i.*)) |metric| {
                        try sm.metrics.append(metric);
                    } else |err| {
                        std.debug.print("MetricReader collect: failed conversion to proto Metric: {?}\n", .{err});
                    }
                }
                try rm.scope_metrics.append(sm);
                try metricsData.resource_metrics.append(rm);
            }
            // Finally, export the metrics data through the exporter.
            // Copy the data to the exporter's memory and each exporter should own it and free it
            // by calling deinit() on the MetricsData once done.
            const owned = try metricsData.dupe(self.allocator);
            switch (self.exporter.exportBatch(owned)) {
                ExportResult.Success => return,
                ExportResult.Failure => return MetricReadError.ExportFailed,
            }
        } else {
            // No meter provider to collect from.
            return MetricReadError.CollectFailedOnMissingMeterProvider;
        }
    }

    pub fn shutdown(self: *Self) void {
        self.collect() catch |e| {
            std.debug.print("MetricReader shutdown: error while collecting metrics: {?}\n", .{e});
        };
        self.hasShutDown.store(true, .release);
        self.exporter.shutdown();
        self.allocator.destroy(self);
    }
};

fn toProtobufMetric(
    allocator: std.mem.Allocator,
    temporality: *const fn (Kind) view.Temporality,
    i: *Instrument,
) !pbmetrics.Metric {
    return pbmetrics.Metric{
        .name = ManagedString.managed(i.opts.name),
        .description = if (i.opts.description) |d| ManagedString.managed(d) else .Empty,
        .unit = if (i.opts.unit) |u| ManagedString.managed(u) else .Empty,
        .data = switch (i.data) {
            .Counter_u16 => pbmetrics.Metric.data_union{ .sum = pbmetrics.Sum{
                .data_points = try sumDataPoints(allocator, u16, i.data.Counter_u16),
                .aggregation_temporality = temporality(i.kind).toProto(),
                .is_monotonic = true,
            } },
            .Counter_u32 => pbmetrics.Metric.data_union{ .sum = pbmetrics.Sum{
                .data_points = try sumDataPoints(allocator, u32, i.data.Counter_u32),
                .aggregation_temporality = temporality(i.kind).toProto(),
                .is_monotonic = true,
            } },

            .Counter_u64 => pbmetrics.Metric.data_union{ .sum = pbmetrics.Sum{
                .data_points = try sumDataPoints(allocator, u64, i.data.Counter_u64),
                .aggregation_temporality = temporality(i.kind).toProto(),
                .is_monotonic = true,
            } },
            .Histogram_u16 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                .data_points = try histogramDataPoints(allocator, u16, i.data.Histogram_u16),
                .aggregation_temporality = temporality(i.kind).toProto(),
            } },

            .Histogram_u32 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                .data_points = try histogramDataPoints(allocator, u32, i.data.Histogram_u32),
                .aggregation_temporality = temporality(i.kind).toProto(),
            } },

            .Histogram_u64 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                .data_points = try histogramDataPoints(allocator, u64, i.data.Histogram_u64),
                .aggregation_temporality = temporality(i.kind).toProto(),
            } },

            .Histogram_f32 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                .data_points = try histogramDataPoints(allocator, f32, i.data.Histogram_f32),
                .aggregation_temporality = temporality(i.kind).toProto(),
            } },
            .Histogram_f64 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                .data_points = try histogramDataPoints(allocator, f64, i.data.Histogram_f64),
                .aggregation_temporality = temporality(i.kind).toProto(),
            } },
            // TODO: add other metrics types.
            else => unreachable,
        },
        // Metadata used for internal translations and we can discard for now.
        // Consumers of SDK should not rely on this field.
        .metadata = std.ArrayList(pbcommon.KeyValue).init(allocator),
    };
}

fn attributeToProtobuf(attribute: Attribute) pbcommon.KeyValue {
    return pbcommon.KeyValue{
        .key = ManagedString.managed(attribute.name),
        .value = switch (attribute.value) {
            .bool => pbcommon.AnyValue{ .value = .{ .bool_value = attribute.value.bool } },
            .string => pbcommon.AnyValue{ .value = .{ .string_value = ManagedString.managed(attribute.value.string) } },
            .int => pbcommon.AnyValue{ .value = .{ .int_value = attribute.value.int } },
            .double => pbcommon.AnyValue{ .value = .{ .double_value = attribute.value.double } },
            // TODO include nested Attribute values
        },
    };
}

fn attributesToProtobufKeyValueList(allocator: std.mem.Allocator, attributes: ?[]Attribute) !pbcommon.KeyValueList {
    if (attributes) |attrs| {
        var kvs = pbcommon.KeyValueList{ .values = std.ArrayList(pbcommon.KeyValue).init(allocator) };
        for (attrs) |a| {
            try kvs.values.append(attributeToProtobuf(a));
        }
        return kvs;
    } else {
        return pbcommon.KeyValueList{ .values = std.ArrayList(pbcommon.KeyValue).init(allocator) };
    }
}

fn sumDataPoints(allocator: std.mem.Allocator, comptime T: type, c: *instr.Counter(T)) !std.ArrayList(pbmetrics.NumberDataPoint) {
    var dataPoints = std.ArrayList(pbmetrics.NumberDataPoint).init(allocator);
    var iter = c.cumulative.iterator();
    while (iter.next()) |measure| {
        var attrs = std.ArrayList(pbcommon.KeyValue).init(allocator);
        // Attributes are stored as key of the hasmap.
        if (measure.key_ptr.*) |kv| {
            for (kv) |a| {
                try attrs.append(attributeToProtobuf(a));
            }
        }
        const dp = pbmetrics.NumberDataPoint{
            .attributes = attrs,
            .time_unix_nano = @intCast(std.time.nanoTimestamp()),
            // FIXME reader's temporailty is not applied here.
            .value = .{ .as_int = @intCast(measure.value_ptr.*) },

            // TODO: support exemplars.
            .exemplars = std.ArrayList(pbmetrics.Exemplar).init(allocator),
        };
        try dataPoints.append(dp);
    }
    return dataPoints;
}

fn histogramDataPoints(allocator: std.mem.Allocator, comptime T: type, h: *instr.Histogram(T)) !std.ArrayList(pbmetrics.HistogramDataPoint) {
    var dataPoints = std.ArrayList(pbmetrics.HistogramDataPoint).init(allocator);
    var iter = h.cumulative.iterator();
    while (iter.next()) |measure| {
        var attrs = std.ArrayList(pbcommon.KeyValue).init(allocator);
        // Attributes are stored as key of the hashmap.
        if (measure.key_ptr.*) |kv| {
            for (kv) |a| {
                try attrs.append(attributeToProtobuf(a));
            }
        }
        var dp = pbmetrics.HistogramDataPoint{
            .attributes = attrs,
            .time_unix_nano = @intCast(std.time.nanoTimestamp()),
            // FIXME reader's temporailty is not applied here.
            .count = h.counts.get(measure.key_ptr.*) orelse 0,
            .sum = switch (@TypeOf(h.*)) {
                instr.Histogram(u16), instr.Histogram(u32), instr.Histogram(u64) => @as(f64, @floatFromInt(measure.value_ptr.*)),
                instr.Histogram(f32), instr.Histogram(f64) => @as(f64, @floatCast(measure.value_ptr.*)),
                else => unreachable,
            },
            .bucket_counts = std.ArrayList(u64).init(allocator),
            .explicit_bounds = std.ArrayList(f64).init(allocator),
            // TODO support exemplars
            .exemplars = std.ArrayList(pbmetrics.Exemplar).init(allocator),
        };
        if (h.bucket_counts.get(measure.key_ptr.*)) |b| {
            try dp.bucket_counts.appendSlice(b);
        }
        try dp.explicit_bounds.appendSlice(h.buckets);

        try dataPoints.append(dp);
    }
    return dataPoints;
}

test "metric reader shutdown prevents collect() to execute" {
    var noop = exporter.ExporterIface{ .exportFn = exporter.noopExporter };
    const me = try MetricExporter.new(std.testing.allocator, &noop);
    var reader = try MetricReader.init(std.testing.allocator, me);
    const e = reader.collect();
    try std.testing.expectEqual(MetricReadError.CollectFailedOnMissingMeterProvider, e);
    reader.shutdown();
}

test "metric reader collects data from meter provider" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(std.testing.allocator);
    defer inMem.deinit();

    var reader = try MetricReader.init(
        std.testing.allocator,
        try MetricExporter.new(std.testing.allocator, &inMem.exporter),
    );
    defer reader.shutdown();

    try mp.addReader(reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    var hist = try m.createHistogram(u16, .{ .name = "my-histogram" });
    const v: []const u8 = "success";

    try hist.record(10, .{ "amazing", v });

    var histFloat = try m.createHistogram(f64, .{ .name = "my-histogram-float" });
    try histFloat.record(10.0, .{ "wonderful", v });

    try reader.collect();
}

fn deltaTemporality(_: Kind) view.Temporality {
    return view.Temporality.Delta;
}

test "metric reader custom temporality" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(std.testing.allocator);
    defer inMem.deinit();

    var reader = try MetricReader.init(
        std.testing.allocator,
        try MetricExporter.new(std.testing.allocator, &inMem.exporter),
    );
    reader = reader.withTemporality(deltaTemporality);

    defer reader.shutdown();

    try mp.addReader(reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    try reader.collect();

    const data = try inMem.fetch();
    defer data.deinit();

    std.debug.assert(data.resource_metrics.items.len == 1);
    std.debug.assert(data.resource_metrics.items[0].scope_metrics.items[0].metrics.items.len == 1);
}

/// A periodic exporting metric reader is a specialization of MetricReader
/// that periodically exports metrics data to a destination.
/// The exporter should be a push-based exporter.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#periodic-exporting-metricreader
pub const PeriodicExportingMetricReader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    exportIntervalMillis: u64,
    exportTimeoutMillis: u64,

    // Lock helper to signal shutdown is in progress
    shuttingDown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // This reader will collect metrics data from the MeterProvider.
    reader: *MetricReader,

    // The intervals at which the reader should export metrics data
    // and wait for each operation to complete.
    // Default values are dicated by the OpenTelemetry specification.
    const defaultExportIntervalMillis: u64 = 60000;
    const defaultExportTimeoutMillis: u64 = 30000;

    pub fn init(
        allocator: std.mem.Allocator,
        reader: *MetricReader,
        exportIntervalMs: ?u64,
        exportTimeoutMs: ?u64,
    ) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .reader = reader,
            .exportIntervalMillis = exportIntervalMs orelse defaultExportIntervalMillis,
            .exportTimeoutMillis = exportTimeoutMs orelse defaultExportTimeoutMillis,
        };
        try s.start();
        return s;
    }

    fn start(self: *Self) !void {
        const th = try std.Thread.spawn(
            .{},
            collectAndExport,
            .{self},
        );
        th.detach();
        return;
    }

    pub fn shutdown(self: *Self) void {
        self.shuttingDown.store(true, .release);
        self.allocator.destroy(self);
    }
};

// Function that collects metrics from the reader and exports it to the destination.
// FIXME there is not a timeout for the collect operation.
fn collectAndExport(periodicExp: *PeriodicExportingMetricReader) void {
    // The execution should continue until the reader is shutting down
    while (periodicExp.shuttingDown.load(.acquire) == false) {
        if (periodicExp.reader.meterProvider) |_| {
            // This will also call exporter.exportBatch() every interval.
            periodicExp.reader.collect() catch |e| {
                std.debug.print("PeriodicExportingReader: reader collect failed: {?}\n", .{e});
            };
        } else {
            std.debug.print("PeriodicExportingReader: no meter provider is registered with this MetricReader {any}\n", .{periodicExp.reader});
        }

        std.time.sleep(periodicExp.exportIntervalMillis * std.time.ns_per_ms);
    }
}

test "e2e periodic exporting metric reader" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const waiting: u64 = 10;

    var inMem = try InMemoryExporter.init(std.testing.allocator);
    defer inMem.deinit();

    var reader = try MetricReader.init(
        std.testing.allocator,
        try MetricExporter.new(std.testing.allocator, &inMem.exporter),
    );
    defer reader.shutdown();

    var pemr = try PeriodicExportingMetricReader.init(
        std.testing.allocator,
        reader,
        waiting,
        null,
    );
    defer pemr.shutdown();

    try mp.addReader(pemr.reader);

    var meter = try mp.getMeter(.{ .name = "test-reader" });
    var counter = try meter.createCounter(u64, .{
        .name = "requests",
        .description = "a test counter",
    });
    try counter.add(10, .{});

    var histogram = try meter.createHistogram(u64, .{
        .name = "latency",
        .description = "a test histogram",
        .histogramOpts = .{ .explicitBuckets = &.{
            1.0,
            10.0,
            100.0,
        } },
    });
    try histogram.record(10, .{});

    std.time.sleep(waiting * 2 * std.time.ns_per_ms);

    const data = try inMem.fetch();
    defer data.deinit();

    std.debug.assert(data.resource_metrics.items.len == 1);
    std.debug.assert(data.resource_metrics.items[0].scope_metrics.items[0].metrics.items.len == 2);
}
