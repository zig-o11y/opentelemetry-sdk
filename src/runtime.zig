const std = @import("std");

const InitState = enum(u8) {
    uninitialized,
    initializing,
    ready,
};

var init_state = std.atomic.Value(InitState).init(.uninitialized);
var threaded_runtime: std.Io.Threaded = undefined;
var threaded_io: std.Io = undefined;

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

pub fn deinit() void {
    switch (init_state.swap(.uninitialized, .acq_rel)) {
        .uninitialized => {},
        .initializing => unreachable,
        .ready => threaded_runtime.deinit(),
    }
}

fn realtimeTimespec() std.c.timespec {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts;
}

pub fn timestamp() i64 {
    const ts = realtimeTimespec();
    return @intCast(ts.sec);
}

pub fn milliTimestamp() i64 {
    const ts = realtimeTimespec();
    return @as(i64, ts.sec) * std.time.ms_per_s + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

pub fn nanoTimestamp() i128 {
    const ts = realtimeTimespec();
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
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

pub const fs = struct {
    pub fn cwdCreateDirPath(path: []const u8) !void {
        return std.Io.Dir.cwd().createDirPath(io(), path);
    }

    pub fn cwdCreateFile(path: []const u8, options: std.Io.Dir.CreateFileOptions) !std.Io.File {
        return std.Io.Dir.cwd().createFile(io(), path, options);
    }

    pub fn cwdDeleteFile(path: []const u8) !void {
        return std.Io.Dir.cwd().deleteFile(io(), path);
    }

    pub fn cwdDeleteTree(path: []const u8) !void {
        return std.Io.Dir.cwd().deleteTree(io(), path);
    }

    pub fn cwdOpenFile(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
        return std.Io.Dir.cwd().openFile(io(), path, options);
    }

    pub fn cwdReadFile(path: []const u8, buffer: []u8) ![]u8 {
        return std.Io.Dir.cwd().readFile(io(), path, buffer);
    }
};
