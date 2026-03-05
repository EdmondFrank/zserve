const std = @import("std");

pub const Logger = struct {
    const Self = @This();

    /// Create a logger that writes to stdout
    pub fn initStdout() Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Log an HTTP request
    pub fn logRequest(
        self: *Self,
        method: []const u8,
        path: []const u8,
        status: u16,
    ) void {
        _ = self;
        const stdout = std.io.getStdOut();
        var ts_buf: [30]u8 = undefined;
        const timestamp = getTimestamp(&ts_buf);

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[{s}] {s} {s} {d}\n", .{
            timestamp,
            method,
            path,
            status,
        }) catch return;

        _ = stdout.write(msg) catch {};
    }

    /// Log an error message
    pub fn logError(self: *Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        const stdout = std.io.getStdOut();
        var ts_buf: [30]u8 = undefined;
        const timestamp = getTimestamp(&ts_buf);

        var buf: [512]u8 = undefined;
        const prefix = std.fmt.bufPrint(&buf, "[{s}] ERROR: ", .{timestamp}) catch return;
        _ = stdout.write(prefix) catch {};
        
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt ++ "\n", args) catch return;
        _ = stdout.write(msg) catch {};
    }

    /// Log an info message
    pub fn logInfo(self: *Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        const stdout = std.io.getStdOut();
        var ts_buf: [30]u8 = undefined;
        const timestamp = getTimestamp(&ts_buf);

        var buf: [512]u8 = undefined;
        const prefix = std.fmt.bufPrint(&buf, "[{s}] INFO: ", .{timestamp}) catch return;
        _ = stdout.write(prefix) catch {};
        
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt ++ "\n", args) catch return;
        _ = stdout.write(msg) catch {};
    }
};

/// Format the current wall-clock time into `buf` and return the written slice.
/// The caller must supply a buffer of at least 30 bytes and must keep it live
/// for as long as the returned slice is used. This avoids the previous bug
/// where a local stack buffer was returned as a slice (use-after-free).
fn getTimestamp(buf: *[30]u8) []const u8 {
    const now = std.time.timestamp();
    const tm = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };

    const year = tm.getEpochYear();
    const month = tm.getMonth();
    const day = tm.getDay();
    const hours = tm.getHoursIntoDay();
    const minutes = tm.getMinutesIntoHour();
    const seconds = tm.getSecondsIntoMinute();

    return std.fmt.bufPrint(buf, "{d}-{s:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year,
        @tagName(month),
        day,
        hours,
        minutes,
        seconds,
    }) catch "timestamp_error";
}
