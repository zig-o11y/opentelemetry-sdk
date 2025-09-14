const std = @import("std");
const trace = @import("../../../api/trace.zig");
const SpanExporter = @import("../span_exporter.zig").SpanExporter;
const otlp = @import("../../../otlp.zig");

const attribute = @import("../../../attributes.zig");

const proto = @import("opentelemetry-proto");
const pbtrace = proto.trace_v1;
const pbcollector_trace = proto.collector_trace_v1;
const pbcommon = proto.common_v1;
const pbresource = proto.resource_v1;

const ManagedString = @import("protobuf").ManagedString;

const InstrumentationScope = @import("../../../scope.zig").InstrumentationScope;

/// OTLPExporter exports trace data using the OpenTelemetry Protocol (OTLP)
pub const OTLPExporter = struct {
    allocator: std.mem.Allocator,
    config: *otlp.ConfigOptions,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: *otlp.ConfigOptions) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .config = config,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn asSpanExporter(self: *Self) SpanExporter {
        return SpanExporter{
            .ptr = self,
            .vtable = &.{
                .exportSpansFn = exportSpans,
                .shutdownFn = shutdown,
            },
        };
    }

    fn exportSpans(ctx: *anyopaque, spans: []trace.Span) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        if (spans.len == 0) return;

        // Convert spans to OTLP format
        const request = try self.spansToOTLPRequest(spans);
        defer self.cleanupRequest(request);
        const otlp_data = otlp.Signal.Data{ .traces = request };

        // Export using the OTLP transport
        return otlp.Export(self.allocator, self.config, otlp_data);
    }

    fn shutdown(_: *anyopaque) anyerror!void {
        // OTLP exporter doesn't require special shutdown
        return;
    }

    fn spansToOTLPRequest(self: *Self, spans: []trace.Span) !pbcollector_trace.ExportTraceServiceRequest {
        var resource_spans = std.ArrayList(pbtrace.ResourceSpans).init(self.allocator);

        // Group spans by instrumentation scope
        var scope_groups = std.HashMap(
            InstrumentationScope,
            std.ArrayList(trace.Span),
            InstrumentationScope.HashContext,
            std.hash_map.default_max_load_percentage,
        ).init(self.allocator);
        defer {
            var iterator = scope_groups.valueIterator();
            while (iterator.next()) |list| {
                list.deinit();
            }
            scope_groups.deinit();
        }

        // Group spans by their instrumentation scope
        for (spans) |span| {
            const scope_key = span.scope;
            const result = try scope_groups.getOrPut(scope_key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(trace.Span).init(self.allocator);
            }
            try result.value_ptr.append(span);
        }

        var scope_spans_list = std.ArrayList(pbtrace.ScopeSpans).init(self.allocator);

        // Convert each scope group to OTLP format
        var scope_iterator = scope_groups.iterator();
        while (scope_iterator.next()) |entry| {
            const scope_spans = entry.value_ptr.*;

            var otlp_spans = std.ArrayList(pbtrace.Span).init(self.allocator);

            // Convert each span to OTLP format
            for (scope_spans.items) |span| {
                const otlp_span = try self.spanToOTLP(span);
                try otlp_spans.append(otlp_span);
            }

            // Create scope information from the first span's scope
            const scope_info = if (scope_spans.items.len > 0)
                scope_spans.items[0].scope
            else
                InstrumentationScope{
                    .name = "unknown",
                    .version = null,
                    .schema_url = null,
                    .attributes = null,
                };

            var scope_attributes = std.ArrayList(pbcommon.KeyValue).init(self.allocator);
            if (scope_info.attributes) |attrs| {
                for (attrs) |attr| {
                    const key_value = try attributeToOTLP(attr.key, attr.value);
                    try scope_attributes.append(key_value);
                }
            }

            const scope_span = pbtrace.ScopeSpans{
                .scope = pbcommon.InstrumentationScope{
                    .name = ManagedString.managed(scope_info.name),
                    .version = ManagedString.managed(scope_info.version orelse ""),
                    .attributes = scope_attributes,
                    .dropped_attributes_count = 0,
                },
                .spans = otlp_spans,
                .schema_url = ManagedString.managed(scope_info.schema_url orelse ""),
            };
            try scope_spans_list.append(scope_span);
        }

        const resource_span = pbtrace.ResourceSpans{
            .resource = pbresource.Resource{
                .attributes = std.ArrayList(pbcommon.KeyValue).init(self.allocator),
                .dropped_attributes_count = 0,
                .entity_refs = std.ArrayList(pbcommon.EntityRef).init(self.allocator),
            },
            .scope_spans = scope_spans_list,
            .schema_url = ManagedString.managed(""),
        };
        try resource_spans.append(resource_span);

        return pbcollector_trace.ExportTraceServiceRequest{
            .resource_spans = resource_spans,
        };
    }

    fn cleanupRequest(_: *Self, request: pbcollector_trace.ExportTraceServiceRequest) void {
        // Clean up the ArrayLists we created
        for (request.resource_spans.items) |resource_span| {
            // Clean up resource attributes
            if (resource_span.resource) |resource| {
                resource.attributes.deinit();
                resource.entity_refs.deinit();
            }

            for (resource_span.scope_spans.items) |scope_span| {
                // Clean up scope attributes
                if (scope_span.scope) |scope| {
                    scope.attributes.deinit();
                }

                // Clean up spans
                for (scope_span.spans.items) |span| {
                    // Clean up span attributes
                    span.attributes.deinit();

                    // Clean up events
                    for (span.events.items) |event| {
                        event.attributes.deinit();
                    }
                    span.events.deinit();

                    // Clean up links
                    for (span.links.items) |link| {
                        link.attributes.deinit();
                    }
                    span.links.deinit();
                }
                scope_span.spans.deinit();
            }
            resource_span.scope_spans.deinit();
        }
        request.resource_spans.deinit();
    }

    fn spanToOTLP(self: *Self, span: trace.Span) !pbtrace.Span {
        const span_context = span.span_context;

        // Convert status
        var status: ?pbtrace.Status = null;
        if (span.status) |span_status| {
            status = pbtrace.Status{
                .message = ManagedString.managed(span_status.description),
                .code = switch (span_status.code) {
                    .Unset => pbtrace.Status.StatusCode.STATUS_CODE_UNSET,
                    .Ok => pbtrace.Status.StatusCode.STATUS_CODE_OK,
                    .Error => pbtrace.Status.StatusCode.STATUS_CODE_ERROR,
                },
            };
        }

        // Convert attributes
        var attributes = std.ArrayList(pbcommon.KeyValue).init(self.allocator);
        for (span.attributes.keys(), span.attributes.values()) |key, value| {
            const key_value = try attributeToOTLP(key, value);
            try attributes.append(key_value);
        }

        // Convert events
        var events = std.ArrayList(pbtrace.Span.Event).init(self.allocator);
        for (span.events.items) |event| {
            var event_attributes = std.ArrayList(pbcommon.KeyValue).init(self.allocator);
            for (event.attributes.keys(), event.attributes.values()) |key, value| {
                const key_value = try attributeToOTLP(key, value);
                try event_attributes.append(key_value);
            }

            const otlp_event = pbtrace.Span.Event{
                .time_unix_nano = event.timestamp,
                .name = ManagedString.managed(event.name),
                .attributes = event_attributes,
                .dropped_attributes_count = 0,
            };
            try events.append(otlp_event);
        }

        // Convert links
        var links = std.ArrayList(pbtrace.Span.Link).init(self.allocator);
        for (span.links.items) |link| {
            var link_attributes = std.ArrayList(pbcommon.KeyValue).init(self.allocator);
            for (link.attributes.keys(), link.attributes.values()) |key, value| {
                const key_value = try attributeToOTLP(key, value);
                try link_attributes.append(key_value);
            }

            const otlp_link = pbtrace.Span.Link{
                .trace_id = blk: {
                    var buf: [32]u8 = undefined;
                    const hex = link.span_context.trace_id.toHex(&buf);
                    break :blk ManagedString.managed(hex);
                },
                .span_id = blk: {
                    var buf: [16]u8 = undefined;
                    const hex = link.span_context.span_id.toHex(&buf);
                    break :blk ManagedString.managed(hex);
                },
                .trace_state = ManagedString.managed(""), // Convert trace state if needed
                .attributes = link_attributes,
                .dropped_attributes_count = 0,
                .flags = @intCast(link.span_context.trace_flags.value),
            };
            try links.append(otlp_link);
        }

        return pbtrace.Span{
            .trace_id = blk: {
                var buf: [32]u8 = undefined;
                const hex = span_context.trace_id.toHex(&buf);
                break :blk ManagedString.managed(hex);
            },
            .span_id = blk: {
                var buf: [16]u8 = undefined;
                const hex = span_context.span_id.toHex(&buf);
                break :blk ManagedString.managed(hex);
            },
            .trace_state = ManagedString.managed(""), // Convert trace state if needed
            .parent_span_id = ManagedString.managed(""), // TODO: get from parent context
            .flags = @intCast(span_context.trace_flags.value),
            .name = ManagedString.managed(span.name),
            .kind = switch (span.kind) {
                .Internal => pbtrace.Span.SpanKind.SPAN_KIND_INTERNAL,
                .Server => pbtrace.Span.SpanKind.SPAN_KIND_SERVER,
                .Client => pbtrace.Span.SpanKind.SPAN_KIND_CLIENT,
                .Producer => pbtrace.Span.SpanKind.SPAN_KIND_PRODUCER,
                .Consumer => pbtrace.Span.SpanKind.SPAN_KIND_CONSUMER,
            },
            .start_time_unix_nano = span.start_time_unix_nano,
            .end_time_unix_nano = span.end_time_unix_nano,
            .attributes = attributes,
            .dropped_attributes_count = 0,
            .events = events,
            .dropped_events_count = 0,
            .links = links,
            .dropped_links_count = 0,
            .status = status,
        };
    }

    fn attributeToOTLP(key: []const u8, value: attribute.AttributeValue) !pbcommon.KeyValue {
        const any_value = switch (value) {
            .string => |v| pbcommon.AnyValue{ .value = .{ .string_value = ManagedString.managed(v) } },
            .bool => |v| pbcommon.AnyValue{ .value = .{ .bool_value = v } },
            .int => |v| pbcommon.AnyValue{ .value = .{ .int_value = v } },
            .double => |v| pbcommon.AnyValue{ .value = .{ .double_value = v } },
        };

        return pbcommon.KeyValue{
            .key = ManagedString.managed(key),
            .value = any_value,
        };
    }
};

test "OTLPExporter with InstrumentationScope" {
    const allocator = std.testing.allocator;

    var config = try otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    var exporter = try OTLPExporter.init(allocator, config);
    defer exporter.deinit();

    // Create test spans with different scopes
    const trace_id = trace.TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    var trace_states: [2]trace.TraceState = undefined;
    var test_spans: [2]trace.Span = undefined;

    for (&trace_states, &test_spans, 0..) |*ts, *span, i| {
        ts.* = trace.TraceState.init(allocator);
        const span_id = trace.SpanID.init([8]u8{ @intCast(i + 1), 2, 3, 4, 5, 6, 7, 8 });
        const span_context = trace.SpanContext.init(trace_id, span_id, trace.TraceFlags.default(), ts.*, false);

        const scope = InstrumentationScope{
            .name = if (i == 0) "lib1" else "lib2",
            .version = "1.0.0",
        };

        span.* = trace.Span.init(allocator, span_context, "test-span", .Internal, scope);
    }

    defer {
        for (&trace_states, &test_spans) |*ts, *span| {
            ts.deinit();
            span.deinit();
        }
    }

    // Test conversion to OTLP request
    const request = try exporter.spansToOTLPRequest(test_spans[0..]);
    defer exporter.cleanupRequest(request);

    // Verify that we have resource spans
    try std.testing.expectEqual(@as(usize, 1), request.resource_spans.items.len);

    const resource_span = request.resource_spans.items[0];

    // Verify that spans are grouped by scope (should have 2 scope spans for 2 different scopes)
    try std.testing.expectEqual(@as(usize, 2), resource_span.scope_spans.items.len);

    // Verify scope information is correct
    var found_lib1 = false;
    var found_lib2 = false;

    for (resource_span.scope_spans.items) |scope_span| {
        if (scope_span.scope) |scope| {
            if (std.meta.eql(scope.name, ManagedString.managed("lib1"))) {
                found_lib1 = true;
                try std.testing.expectEqual(ManagedString.managed("1.0.0"), scope.version);
                try std.testing.expectEqual(@as(usize, 1), scope_span.spans.items.len);
            } else if (std.meta.eql(scope.name, ManagedString.managed("lib2"))) {
                found_lib2 = true;
                try std.testing.expectEqual(ManagedString.managed("1.0.0"), scope.version);
                try std.testing.expectEqual(@as(usize, 1), scope_span.spans.items.len);
            }
        }
    }

    try std.testing.expect(found_lib1);
    try std.testing.expect(found_lib2);
}

test "OTLPExporter basic functionality" {
    const allocator = std.testing.allocator;

    var config = try otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    var exporter = try OTLPExporter.init(allocator, config);
    defer exporter.deinit();

    const span_exporter = exporter.asSpanExporter();

    // Create a test span
    const trace_id = trace.TraceID.init([16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    const span_id = trace.SpanID.init([8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    var trace_state = trace.TraceState.init(allocator);
    defer trace_state.deinit();

    const span_context = trace.SpanContext.init(trace_id, span_id, trace.TraceFlags.default(), trace_state, false);
    const scope = InstrumentationScope{ .name = "test-lib", .version = "1.0.0" };
    var test_span = trace.Span.init(allocator, span_context, "test-span", .Internal, scope);
    defer test_span.deinit();

    var spans = [_]trace.Span{test_span};

    // Test conversion to OTLP (this will fail to send to server, but that's ok for the test)
    const result = span_exporter.exportSpans(spans[0..]);
    // We expect a connection error since there's no OTLP server running
    try std.testing.expectError(std.posix.ConnectError.ConnectionRefused, result);
}
