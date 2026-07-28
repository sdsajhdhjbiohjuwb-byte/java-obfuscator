const std = @import("std");

var IoHandle: std.Io = undefined;
var StartStamp: std.Io.Timestamp = std.Io.Timestamp.zero;
var Ready: bool = false;

fn Now() std.Io.Timestamp {
    return std.Io.Clock.now(.awake, IoHandle);
}

fn WallSeconds() f64 {
    if (!Ready) return 0.0;
    const Millis = StartStamp.durationTo(Now()).toMilliseconds();
    return @as(f64, @floatFromInt(Millis)) / 1000.0;
}

pub const Task = struct {
    Stamp: std.Io.Timestamp,
    Buffer: [96]u8,
    Length: usize,

    fn Label(Self: *const Task) []const u8 {
        return Self.Buffer[0..@min(Self.Length, 20)];
    }

    pub fn Done(Self: *const Task, comptime Fmt: []const u8, Args: anytype) void {
        const Elapsed: u64 = @intCast(@max(Self.Stamp.durationTo(Now()).toMilliseconds(), 0));
        var Line: [320]u8 = undefined;
        const Head = std.fmt.bufPrint(&Line, "[{d:>8.3}s]  DONE   {s: <20} {d: >6} ms  ", .{ WallSeconds(), Self.Label(), Elapsed }) catch return;
        const Rest = std.fmt.bufPrint(Line[Head.len..], Fmt, Args) catch Line[Head.len..Head.len];
        std.debug.print("{s}\n", .{Line[0 .. Head.len + Rest.len]});
    }
};

pub fn Begin(Io: std.Io, InputPath: []const u8) void {
    IoHandle = Io;
    StartStamp = Now();
    Ready = true;
    std.debug.print("\n[   0.000s]  Program: obfuscating {s}\n", .{InputPath});
}

pub fn Start(comptime Fmt: []const u8, Args: anytype) Task {
    var Value: Task = .{ .Stamp = Now(), .Buffer = undefined, .Length = 0 };
    const Written = std.fmt.bufPrint(&Value.Buffer, Fmt, Args) catch Value.Buffer[0..0];
    Value.Length = Written.len;
    std.debug.print("[{d:>8.3}s]  START  {s}\n", .{ WallSeconds(), Written });
    return Value;
}

pub fn Sub(comptime Fmt: []const u8, Args: anytype) void {
    var Line: [256]u8 = undefined;
    const Head = std.fmt.bufPrint(&Line, "[{d:>8.3}s]           - ", .{WallSeconds()}) catch return;
    const Rest = std.fmt.bufPrint(Line[Head.len..], Fmt, Args) catch Line[Head.len..Head.len];
    std.debug.print("{s}\n", .{Line[0 .. Head.len + Rest.len]});
}

pub fn Metrics() void {
    std.debug.print("[{d:>8.3}s]  METRICS\n", .{WallSeconds()});
}

pub fn Metric(Name: []const u8, Value: usize) void {
    std.debug.print("[{d:>8.3}s]           - {s: <24}{d: >8}\n", .{ WallSeconds(), Name, Value });
}

pub fn Wrote(Name: []const u8, Directory: []const u8, ByteCount: usize) void {
    std.debug.print("[{d:>8.3}s]  WROTE  {s} ({s}, {d} bytes)\n", .{ WallSeconds(), Name, Directory, ByteCount });
}

pub fn Failure(Err: anyerror) void {
    std.debug.print("[{d:>8.3}s]  FAILED {s}\n", .{ WallSeconds(), @errorName(Err) });
}
