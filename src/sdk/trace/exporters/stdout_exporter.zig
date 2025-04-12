const std = @import("std");

const trace = @import("../../../api/trace.zig");
const SpanExporter = @import("../span_exporter.zig").SpanExporter;

/// GenericWriterExporter is the generic SpanExporter that outputs spans to the given writer.
fn GenericWriterExporter(
    comptime Writer: type,
) type {
    return struct {
        writer: Writer,

        const Self = @This();

        pub fn init(writer: Writer) Self {
            return Self{
                .writer = writer,
            };
        }

        pub fn exportSpans(ctx: *anyopaque, spans: []trace.Span) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try std.json.stringify(spans, .{}, self.writer);
        }

        pub fn shutdown(_: *anyopaque) anyerror!void {}

        pub fn asSpanExporter(self: *Self) SpanExporter {
            return .{
                .ptr = self,
                .vtable = &.{
                    .exportSpansFn = exportSpans,
                    .shutdownFn = shutdown,
                },
            };
        }
    };
}

/// StdoutExporter outputs spans into OS stdout.
/// ref: https://opentelemetry.io/docs/specs/otel/trace/sdk_exporters/stdout/
pub const StdoutExporter = GenericWriterExporter(std.io.Writer(std.fs.File, std.fs.File.WriteError, std.fs.File.write));

/// InmemoryExporter exports spans to in-memory buffer.
/// it is designed for testing GenericWriterExporter.
pub const InmemoryExporter = GenericWriterExporter(std.ArrayList(u8).Writer);

test "GenericWriterExporter" {
    var out_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer out_buf.deinit();
    var inmemory_exporter = InmemoryExporter.init(out_buf.writer());
    var exporter = inmemory_exporter.asSpanExporter();

    var spans = [_]trace.Span{
        .{},
    };
    try exporter.exportSpans(spans[0..spans.len]);

    const expected = "";
    try std.testing.expectEqualSlices(u8, expected[0..expected.len], out_buf.items);
    std.debug.print("{s}", .{out_buf.items});
    // TODO: detailed output test
}
