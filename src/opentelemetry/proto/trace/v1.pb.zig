// Code generated by protoc-gen-zig
///! package opentelemetry.proto.trace.v1
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const fd = protobuf.fd;
/// import package opentelemetry.proto.common.v1
const opentelemetry_proto_common_v1 = @import("../common/v1.pb.zig");
/// import package opentelemetry.proto.resource.v1
const opentelemetry_proto_resource_v1 = @import("../resource/v1.pb.zig");

pub const SpanFlags = enum(i32) {
    SPAN_FLAGS_DO_NOT_USE = 0,
    SPAN_FLAGS_TRACE_FLAGS_MASK = 255,
    SPAN_FLAGS_CONTEXT_HAS_IS_REMOTE_MASK = 256,
    SPAN_FLAGS_CONTEXT_IS_REMOTE_MASK = 512,
    _,
};

pub const TracesData = struct {
    resource_spans: ArrayList(ResourceSpans),

    pub const _desc_table = .{
        .resource_spans = fd(1, .{ .List = .{ .SubMessage = {} } }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const ResourceSpans = struct {
    resource: ?opentelemetry_proto_resource_v1.Resource = null,
    scope_spans: ArrayList(ScopeSpans),
    schema_url: ManagedString = .Empty,

    pub const _desc_table = .{
        .resource = fd(1, .{ .SubMessage = {} }),
        .scope_spans = fd(2, .{ .List = .{ .SubMessage = {} } }),
        .schema_url = fd(3, .String),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const ScopeSpans = struct {
    scope: ?opentelemetry_proto_common_v1.InstrumentationScope = null,
    spans: ArrayList(Span),
    schema_url: ManagedString = .Empty,

    pub const _desc_table = .{
        .scope = fd(1, .{ .SubMessage = {} }),
        .spans = fd(2, .{ .List = .{ .SubMessage = {} } }),
        .schema_url = fd(3, .String),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const Span = struct {
    trace_id: ManagedString = .Empty,
    span_id: ManagedString = .Empty,
    trace_state: ManagedString = .Empty,
    parent_span_id: ManagedString = .Empty,
    flags: u32 = 0,
    name: ManagedString = .Empty,
    kind: SpanKind = @enumFromInt(0),
    start_time_unix_nano: u64 = 0,
    end_time_unix_nano: u64 = 0,
    attributes: ArrayList(opentelemetry_proto_common_v1.KeyValue),
    dropped_attributes_count: u32 = 0,
    events: ArrayList(Event),
    dropped_events_count: u32 = 0,
    links: ArrayList(Link),
    dropped_links_count: u32 = 0,
    status: ?Status = null,

    pub const _desc_table = .{
        .trace_id = fd(1, .Bytes),
        .span_id = fd(2, .Bytes),
        .trace_state = fd(3, .String),
        .parent_span_id = fd(4, .Bytes),
        .flags = fd(16, .{ .FixedInt = .I32 }),
        .name = fd(5, .String),
        .kind = fd(6, .{ .Varint = .Simple }),
        .start_time_unix_nano = fd(7, .{ .FixedInt = .I64 }),
        .end_time_unix_nano = fd(8, .{ .FixedInt = .I64 }),
        .attributes = fd(9, .{ .List = .{ .SubMessage = {} } }),
        .dropped_attributes_count = fd(10, .{ .Varint = .Simple }),
        .events = fd(11, .{ .List = .{ .SubMessage = {} } }),
        .dropped_events_count = fd(12, .{ .Varint = .Simple }),
        .links = fd(13, .{ .List = .{ .SubMessage = {} } }),
        .dropped_links_count = fd(14, .{ .Varint = .Simple }),
        .status = fd(15, .{ .SubMessage = {} }),
    };

    pub const SpanKind = enum(i32) {
        SPAN_KIND_UNSPECIFIED = 0,
        SPAN_KIND_INTERNAL = 1,
        SPAN_KIND_SERVER = 2,
        SPAN_KIND_CLIENT = 3,
        SPAN_KIND_PRODUCER = 4,
        SPAN_KIND_CONSUMER = 5,
        _,
    };

    pub const Event = struct {
        time_unix_nano: u64 = 0,
        name: ManagedString = .Empty,
        attributes: ArrayList(opentelemetry_proto_common_v1.KeyValue),
        dropped_attributes_count: u32 = 0,

        pub const _desc_table = .{
            .time_unix_nano = fd(1, .{ .FixedInt = .I64 }),
            .name = fd(2, .String),
            .attributes = fd(3, .{ .List = .{ .SubMessage = {} } }),
            .dropped_attributes_count = fd(4, .{ .Varint = .Simple }),
        };

        pub usingnamespace protobuf.MessageMixins(@This());
    };

    pub const Link = struct {
        trace_id: ManagedString = .Empty,
        span_id: ManagedString = .Empty,
        trace_state: ManagedString = .Empty,
        attributes: ArrayList(opentelemetry_proto_common_v1.KeyValue),
        dropped_attributes_count: u32 = 0,
        flags: u32 = 0,

        pub const _desc_table = .{
            .trace_id = fd(1, .Bytes),
            .span_id = fd(2, .Bytes),
            .trace_state = fd(3, .String),
            .attributes = fd(4, .{ .List = .{ .SubMessage = {} } }),
            .dropped_attributes_count = fd(5, .{ .Varint = .Simple }),
            .flags = fd(6, .{ .FixedInt = .I32 }),
        };

        pub usingnamespace protobuf.MessageMixins(@This());
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const Status = struct {
    message: ManagedString = .Empty,
    code: StatusCode = @enumFromInt(0),

    pub const _desc_table = .{
        .message = fd(2, .String),
        .code = fd(3, .{ .Varint = .Simple }),
    };

    pub const StatusCode = enum(i32) {
        STATUS_CODE_UNSET = 0,
        STATUS_CODE_OK = 1,
        STATUS_CODE_ERROR = 2,
        _,
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};
