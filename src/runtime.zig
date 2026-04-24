const std = @import("std");

const InitState = enum(u8) {
    uninitialized,
    initializing,
    ready,
};

var init_state = std.atomic.Value(InitState).init(.uninitialized);
var threaded_runtime: std.Io.Threaded = undefined;
var threaded_io: std.Io = undefined;
var owns_runtime = std.atomic.Value(bool).init(false);

/// Global runtime abstraction for the OpenTelemetry SDK.
///
/// For Zig 0.16, we use a lazy-initialized global std.Io.Threaded because
/// std.Io is the first-class I/O abstraction. Users who need a custom Io
/// (e.g. for testing or evented mode) can call setIo() before any SDK usage.
///
/// Lifecycle: the global runtime lives for the process lifetime. There is no
/// reference counting because the OTel spec encourages multiple independent
/// providers but does not require global runtime teardown. Each provider's
/// processors manage their own background threads. See runtime.deinit() docs.
/// Override the default Io instance. Must be called before any SDK usage.
/// If not called, the SDK lazily initializes a global std.Io.Threaded.
///
/// This is a one-time setter: once the runtime has transitioned out of
/// .uninitialized (either via this function or lazy init in io()), the
/// global Io is fixed.  Callers who need a custom Io must set it before
/// any SDK component calls runtime.io().
pub fn setIo(new_io: std.Io) void {
    while (true) {
        switch (init_state.load(.acquire)) {
            .ready => @panic("setIo() called after runtime was already initialized. " ++
                "It must be called before any SDK usage."),
            .uninitialized => {
                if (init_state.cmpxchgStrong(.uninitialized, .initializing, .acq_rel, .acquire) == null) {
                    threaded_io = new_io;
                    init_state.store(.ready, .release);
                    return;
                }
            },
            .initializing => std.Thread.yield() catch {},
        }
    }
}

pub const EnvMap = std.process.Environ.Map;

fn currentEnvironBlock() std.process.Environ.Block {
    if (@hasDecl(std.process.Environ.Block, "global")) {
        return std.process.Environ.Block.global;
    }

    var env_count: usize = 0;
    while (std.c.environ[env_count] != null) : (env_count += 1) {}
    const environ: [:null]const ?[*:0]const u8 = @ptrCast(std.c.environ[0..env_count :null]);
    return .{ .slice = environ };
}

fn ensureInitialized() void {
    while (true) {
        switch (init_state.load(.acquire)) {
            .ready => return,
            .uninitialized => {
                if (init_state.cmpxchgStrong(.uninitialized, .initializing, .acq_rel, .acquire) == null) {
                    threaded_runtime = std.Io.Threaded.init(std.heap.page_allocator, .{});
                    threaded_io = threaded_runtime.io();
                    owns_runtime.store(true, .release);
                    init_state.store(.ready, .release);
                    return;
                }
            },
            .initializing => std.Thread.yield() catch {},
        }
    }
}

pub fn io() std.Io {
    ensureInitialized();
    return threaded_io;
}

/// Tear down the global threaded runtime.
///
/// WARNING: This should only be called when ALL OpenTelemetry providers,
/// processors, and exporters have been shut down and no background threads
/// are using the runtime. Calling deinit() while any SDK component is still
/// active will cause crashes or hangs.
///
/// The global runtime is intended
/// to live for the process lifetime. Explicit deinit() is provided mainly
/// for test environments that need strict leak detection.
pub fn deinit() void {
    switch (init_state.swap(.uninitialized, .acq_rel)) {
        .uninitialized => {},
        .initializing => unreachable,
        .ready => if (owns_runtime.swap(false, .acq_rel)) threaded_runtime.deinit(),
    }
}

fn realtimeTimespec() std.c.timespec {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts;
}

/// Wall-clock timestamp in seconds since UNIX epoch.
/// Uses CLOCK_REALTIME. Suitable for absolute span timestamps per OTel spec.
/// NOTE: Subject to NTP adjustments and wall-clock jumps.
pub fn timestamp() i64 {
    const ts = realtimeTimespec();
    return @intCast(ts.sec);
}

/// Wall-clock timestamp in milliseconds since UNIX epoch.
/// Uses CLOCK_REALTIME. Suitable for absolute span timestamps per OTel spec.
/// NOTE: Subject to NTP adjustments and wall-clock jumps.
pub fn milliTimestamp() i64 {
    const ts = realtimeTimespec();
    return @as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

/// Wall-clock timestamp in nanoseconds since UNIX epoch.
/// Uses CLOCK_REALTIME. Suitable for absolute span start/end times per OTel spec.
/// NOTE: Subject to NTP adjustments and wall-clock jumps.
pub fn nanoTimestamp() i128 {
    const ts = realtimeTimespec();
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn monotonicTimespec() std.c.timespec {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return ts;
}

/// Monotonic nanoseconds suitable for elapsed-time measurements.
/// Does not suffer from wall-clock adjustments (NTP, DST, etc.).
pub fn monotonicNs() u64 {
    const ts = monotonicTimespec();
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn sleep(ns: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

pub fn timeoutAfterNs(ns: u64) std.Io.Timeout {
    return .{
        .duration = .{
            .raw = .{ .nanoseconds = @intCast(ns) },
            .clock = .awake,
        },
    };
}

pub fn timeoutAfterMs(ms: u64) std.Io.Timeout {
    // NOTE: ms is u64, and u64::MAX * ns_per_ms < i96::MAX, so this cast
    // cannot overflow with the current call sites. If this function is ever
    // widened to accept u128, the multiplication must be bounded.
    return .{
        .duration = .{
            .raw = .{ .nanoseconds = @as(i96, @intCast(ms)) * std.time.ns_per_ms },
            .clock = .awake,
        },
    };
}

pub fn waitTimeout(event: *std.Io.Event, ns: u64) (error{Timeout} || std.Io.Cancelable)!void {
    return event.waitTimeout(io(), timeoutAfterNs(ns));
}

pub fn createEnvMap(allocator: std.mem.Allocator) !EnvMap {
    return std.process.Environ.createMap(.{ .block = currentEnvironBlock() }, allocator);
}

