const std = @import("std");
const Io = std.Io;

const url = @import("url.zig");
const http = @import("http.zig");
const directory = @import("directory.zig");
const file_server = @import("file_server.zig");
const upload = @import("upload.zig");

pub const ConnectionContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    root_dir: Io.Dir,
};

/// Handle a connection
pub fn handleConnection(ctx: ConnectionContext) !void {
    defer ctx.stream.close(ctx.io);

    // Create reader with buffer
    var read_buf: [8192]u8 = undefined;
    var stream_reader = ctx.stream.reader(ctx.io, &read_buf);

    // Create a temporary writer to capture request
    var req_buf: [8192]u8 = undefined;
    var temp_writer = Io.Writer.fixed(&req_buf);

    // Read request data using stream
    const n = stream_reader.interface.stream(&temp_writer, .limited(8192)) catch |err| {
        std.debug.print("Error reading from stream: {s}\n", .{@errorName(err)});
        return;
    };
    const request_raw = req_buf[0..n];

    // Parse HTTP request
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    const request = http.parseRequest(arena.allocator(), request_raw) catch |err| {
        std.debug.print("Error parsing request: {s}\n", .{@errorName(err)});
        http.sendBadRequest(ctx.stream, ctx.io, "Invalid HTTP request") catch {};
        return;
    };

    std.debug.print("{s} {s}\n", .{ request.method.toString(), request.path });

    // Handle file upload endpoint
    if (request.method == .POST and std.mem.eql(u8, request.path, "/upload")) {
        // Read the full request body for upload
        const body = try readRequestBody(ctx, &stream_reader, &request, request_raw);
        upload.handleUpload(ctx.io, arena.allocator(), ctx.stream, ctx.root_dir, request, body) catch |err| {
            std.debug.print("Error handling upload: {s}\n", .{@errorName(err)});
        };
        return;
    }

    // URL decode the path
    const decoded_path = url.decode(arena.allocator(), request.path) catch |err| {
        std.debug.print("Error decoding URL: {s}\n", .{@errorName(err)});
        http.sendBadRequest(ctx.stream, ctx.io, "Invalid URL encoding") catch {};
        return;
    };

    // Check for directory traversal attacks
    if (url.hasTraversal(decoded_path)) {
        http.sendNotFound(ctx.stream, ctx.io) catch {};
        return;
    }

    // Normalize path
    const path = url.normalizePath(decoded_path);
    const path_to_open = if (path.len == 0) "." else path;

    // Try to open as directory first
    if (ctx.root_dir.openDir(ctx.io, path_to_open, .{ .iterate = true })) |dir| {
        defer dir.close(ctx.io);
        directory.listDirectory(ctx.io, arena.allocator(), ctx.stream, path_to_open, ctx.root_dir) catch |err| {
            std.debug.print("Error listing directory: {s}\n", .{@errorName(err)});
        };
        return;
    } else |_| {
        // Not a directory, try as file
        file_server.serveFile(ctx.io, arena.allocator(), ctx.stream, path_to_open, ctx.root_dir, request_raw) catch |err| {
            std.debug.print("File not found: {s} ({s})\n", .{ path_to_open, @errorName(err) });
            http.sendNotFound(ctx.stream, ctx.io) catch {};
        };
    }
}

/// Read the full request body based on Content-Length
fn readRequestBody(
    ctx: ConnectionContext,
    stream_reader: anytype,
    request: *const http.Request,
    request_raw: []const u8,
) ![]const u8 {
    // Get Content-Length header
    const content_length_str = request.headers.get("Content-Length") orelse return "";
    const content_length = std.fmt.parseInt(usize, content_length_str, 10) catch return "";

    if (content_length == 0) return "";

    // Check if body is already in the request buffer (after headers)
    const header_end = findBodyStart(request_raw) orelse 0;
    const already_read = if (header_end > 0 and header_end < request_raw.len)
        request_raw.len - header_end
    else
        0;

    if (already_read >= content_length) {
        return request_raw[header_end..][0..content_length];
    }

    // Allocate buffer for full body
    const body = try ctx.allocator.alloc(u8, content_length);
    errdefer ctx.allocator.free(body);

    // Copy what we already have
    if (already_read > 0) {
        @memcpy(body[0..already_read], request_raw[header_end..]);
    }

    // Read remaining data using buffered approach
    var pos = already_read;
    var read_buffer: [4096]u8 = undefined;

    while (pos < content_length) {
        const remaining = content_length - pos;
        const to_read = @min(read_buffer.len, remaining);

        var temp_writer = Io.Writer.fixed(read_buffer[0..to_read]);
        const n = stream_reader.interface.stream(&temp_writer, .limited(to_read)) catch |err| {
            std.debug.print("Error reading body at pos {d}: {s}\n", .{ pos, @errorName(err) });
            break;
        };

        if (n == 0) {
            std.debug.print("EOF reached at pos {d}, expected {d}\n", .{ pos, content_length });
            break;
        }

        @memcpy(body[pos .. pos + n], read_buffer[0..n]);
        pos += n;
    }

    // If we didn't read everything, resize the buffer
    if (pos < content_length) {
        return ctx.allocator.realloc(body, pos);
    }

    return body;
}

/// Find the start of the request body (after \r\n\r\n)
fn findBodyStart(data: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, data, "\r\n\r\n") orelse
        std.mem.indexOf(u8, data, "\n\n") orelse
        return null;
    return idx + 4; // Skip past \r\n\r\n
}
