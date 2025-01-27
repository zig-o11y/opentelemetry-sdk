const std = @import("std");

const attribute = @import("../../attributes.zig");
const trace = @import("../trace.zig");
const pb = @import("../../opentelemetry/proto/trace/v1.pb.zig");

/// Span represents a span of a trace.
/// It is the only component that depends protobuf definition.
pub const Span = struct {
    trace_id: trace.TraceID = trace.TraceID.zero(),
    span_id: trace.SpanID = trace.SpanID.zero(),
    // TODO: maybe not string
    trace_state: []const u8 = "",
    parent_span_id: ?trace.SpanID = null,
    flags: u32 = 0,
    name: []const u8 = "",
    kind: SpanKind = SpanKind.Unspecified,
    start_time_unix_nano: u64 = 0,
    end_time_unix_nano: u64 = 0,
    attributes: []attribute.Attribute = undefined,
    // dropped_attributes_count
    events: []trace.Event,
    // dropped_events_count
    links: []trace.Link = undefined,
    // dropped_links_count
    status: ?Status = null,
};

pub const SpanKind = enum {
    Unspecified,
    Internal,
    Server,
    Client,
    Producer,
    Consumer,
};

pub const Status = struct {
    code: trace.Code,
    description: []const u8,
};