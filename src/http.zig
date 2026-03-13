const std = @import("std");
const Io = std.Io;

pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    OPTIONS,
    PATCH,

    pub fn fromString(str: []const u8) ?Method {
        if (std.mem.eql(u8, str, "GET")) return .GET;
        if (std.mem.eql(u8, str, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, str, "POST")) return .POST;
        if (std.mem.eql(u8, str, "PUT")) return .PUT;
        if (std.mem.eql(u8, str, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, str, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, str, "PATCH")) return .PATCH;
        return null;
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .HEAD => "HEAD",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .OPTIONS => "OPTIONS",
            .PATCH => "PATCH",
        };
    }
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    version: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Request) void {
        // Free header keys and values
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        self.allocator.free(self.path);
    }
};

pub const Range = struct {
    start: u64,
    end: ?u64,
};

pub const StatusCode = enum(u16) {
    ok = 200,
    partial_content = 206,
    not_found = 404,
    bad_request = 400,
    internal_server_error = 500,
    payload_too_large = 413,

    pub fn toText(self: StatusCode) []const u8 {
        return switch (self) {
            .ok => "OK",
            .partial_content => "Partial Content",
            .not_found => "Not Found",
            .bad_request => "Bad Request",
            .internal_server_error => "Internal Server Error",
            .payload_too_large => "Payload Too Large",
        };
    }
};

/// Parse an HTTP request from raw bytes
pub fn parseRequest(allocator: std.mem.Allocator, raw: []const u8) !Request {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    const first_line = lines.first();

    // Parse request line: METHOD PATH VERSION
    var tokens = std.mem.splitScalar(u8, first_line, ' ');
    const method_str = tokens.next() orelse return error.InvalidRequest;
    const path = tokens.next() orelse return error.InvalidRequest;
    const version_raw = tokens.next() orelse "HTTP/1.1";
    const version = std.mem.trim(u8, version_raw, " \r");

    const method = Method.fromString(method_str) orelse return error.InvalidMethod;

    // Parse headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer headers.deinit();

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n");
        if (trimmed.len == 0) break;

        if (std.mem.indexOf(u8, trimmed, ": ")) |colon| {
            const key = try allocator.dupe(u8, std.mem.trim(u8, trimmed[0..colon], " "));
            const value = try allocator.dupe(u8, std.mem.trim(u8, trimmed[colon + 2 ..], " "));
            try headers.put(key, value);
        }
    }

    return Request{
        .method = method,
        .path = try allocator.dupe(u8, path),
        .version = version,
        .headers = headers,
        .body = "",
        .allocator = allocator,
    };
}

/// Parse a Range header value
pub fn parseRange(range_header: []const u8, file_size: u64) !Range {
    if (!std.mem.startsWith(u8, range_header, "bytes=")) return error.InvalidRange;
    const range_value = range_header["bytes=".len..];

    var it = std.mem.splitScalar(u8, range_value, '-');
    const start_str = it.first();
    const end_str = it.next() orelse return error.InvalidRange;

    const start = std.fmt.parseInt(u64, start_str, 10) catch return error.InvalidRange;
    const end = if (end_str.len > 0)
        try std.fmt.parseInt(u64, end_str, 10)
    else
        null;

    if (end) |e| {
        if (e < start or e >= file_size) return error.InvalidRange;
    }
    if (start >= file_size) return error.InvalidRange;

    return Range{ .start = start, .end = end };
}

/// Send an HTTP response status line and headers
pub fn sendResponseHeaders(
    stream: Io.net.Stream,
    io: Io,
    status: StatusCode,
    headers: []const struct { []const u8, []const u8 },
) !void {
    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    var msg = std.ArrayList(u8).initCapacity(allocator, 1024) catch return error.OutOfMemory;

    // Build status line directly
    try msg.appendSlice(allocator, "HTTP/1.1 ");
    const status_code = @intFromEnum(status);
    switch (status_code) {
        200 => try msg.appendSlice(allocator, "200 OK\r\n"),
        206 => try msg.appendSlice(allocator, "206 Partial Content\r\n"),
        400 => try msg.appendSlice(allocator, "400 Bad Request\r\n"),
        404 => try msg.appendSlice(allocator, "404 Not Found\r\n"),
        500 => try msg.appendSlice(allocator, "500 Internal Server Error\r\n"),
        else => try msg.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d} {s}\r\n", .{ status_code, status.toText() })),
    }

    for (headers) |header| {
        try msg.appendSlice(allocator, header[0]);
        try msg.appendSlice(allocator, ": ");
        try msg.appendSlice(allocator, header[1]);
        try msg.appendSlice(allocator, "\r\n");
    }

    try msg.appendSlice(allocator, "\r\n");

    // Use the stream writer and flush
    var write_buf: [8192]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    try stream_writer.interface.writeAll(msg.items);
    try stream_writer.interface.flush();
}

/// Send an HTTP error response
pub fn sendErrorResponse(stream: Io.net.Stream, io: Io, status: StatusCode, message: []const u8) !void {
    try sendResponseHeaders(stream, io, status, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/html; charset=utf-8" },
    });

    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    var msg = std.ArrayList(u8).initCapacity(allocator, 512) catch return;
    try msg.appendSlice(allocator, "<html><body><h1>");
    const status_line = std.fmt.bufPrint(buf[0..50], "{d} {s}", .{ @intFromEnum(status), status.toText() }) catch return;
    try msg.appendSlice(allocator, status_line);
    try msg.appendSlice(allocator, "</h1><p>");
    try msg.appendSlice(allocator, message);
    try msg.appendSlice(allocator, "</p></body></html>");

    var write_buf: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    try stream_writer.interface.writeAll(msg.items);
    try stream_writer.interface.flush();
}

/// Send a 404 Not Found response
pub fn sendNotFound(stream: Io.net.Stream, io: Io) !void {
    try sendErrorResponse(stream, io, .not_found, "The requested resource was not found.");
}

/// Send a 400 Bad Request response
pub fn sendBadRequest(stream: Io.net.Stream, io: Io, message: []const u8) !void {
    try sendErrorResponse(stream, io, .bad_request, message);
}

/// Send a 500 Internal Server Error response
pub fn sendInternalServerError(stream: Io.net.Stream, io: Io) !void {
    try sendErrorResponse(stream, io, .internal_server_error, "An internal server error occurred.");
}
