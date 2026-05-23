const std = @import("std");
const Io = std.Io;

/// Maximum request body size (10MB) to prevent DoS attacks
const MAX_BODY_SIZE = 10 * 1024 * 1024;

const url = @import("url.zig");
const http = @import("http.zig");
const directory = @import("directory.zig");
const file_server = @import("file_server.zig");
const upload = @import("upload.zig");
const delete_file = @import("delete.zig");
const tail = @import("tail.zig");
const truncate_file = @import("truncate.zig");
const execute = @import("execute.zig");
const git_view = @import("git_view.zig");

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
        // Use arena allocator so the body is freed automatically when the arena is deinitialized
        const body = readRequestBody(arena.allocator(), &stream_reader, &request, request_raw) catch |err| {
            if (err == error.RequestTooLarge) {
                http.sendErrorResponse(ctx.stream, ctx.io, .payload_too_large, "Request body too large (max 10MB)") catch {};
            } else {
                std.debug.print("Error reading request body: {s}\n", .{@errorName(err)});
            }
            return;
        };
        upload.handleUpload(ctx.io, arena.allocator(), ctx.stream, ctx.root_dir, request, body) catch |err| {
            std.debug.print("Error handling upload: {s}\n", .{@errorName(err)});
        };
        return;
    }

    // Handle file delete endpoint
    if (request.method == .DELETE) {
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

        // Normalize path (remove leading /)
        const path = if (std.mem.startsWith(u8, decoded_path, "/"))
            decoded_path[1..]
        else
            decoded_path;

        delete_file.handleDelete(ctx.io, arena.allocator(), ctx.stream, ctx.root_dir, path) catch |err| {
            std.debug.print("Error handling delete: {s}\n", .{@errorName(err)});
        };
        return;
    }

    // Handle file truncate endpoint
    if (request.method == .POST and std.mem.startsWith(u8, request.path, "/truncate?file=")) {
        const encoded_file_path = request.path[15..]; // Skip "/truncate?file="

        // URL decode the file path
        const file_path = url.decode(arena.allocator(), encoded_file_path) catch |err| {
            std.debug.print("Error decoding URL: {s}\n", .{@errorName(err)});
            http.sendBadRequest(ctx.stream, ctx.io, "Invalid URL encoding") catch {};
            return;
        };

        // Check for directory traversal attacks
        if (url.hasTraversal(file_path)) {
            http.sendNotFound(ctx.stream, ctx.io) catch {};
            return;
        }

        // Normalize path (remove leading /)
        const path = if (std.mem.startsWith(u8, file_path, "/"))
            file_path[1..]
        else
            file_path;

        truncate_file.handleTruncate(ctx.io, arena.allocator(), ctx.stream, ctx.root_dir, path) catch |err| {
            std.debug.print("Error handling truncate: {s}\n", .{@errorName(err)});
        };
        return;
    }

    // Handle tail endpoint (log file streaming)
    if (std.mem.startsWith(u8, request.path, "/tail")) {
        if (std.mem.startsWith(u8, request.path, "/tail/stream")) {
            // Get file path from query strings
            const query_start = std.mem.indexOf(u8, request.path, "?file=");
            if (query_start) |idx| {
                const file_path = request.path[idx + 6 ..]; // Skip "?file="
                tail.handleTailStream(ctx.io, arena.allocator(), ctx.stream, ctx.root_dir, file_path) catch |err| {
                    std.debug.print("Error handling tail stream: {s}\n", .{@errorName(err)});
                };
            } else {
                http.sendBadRequest(ctx.stream, ctx.io, "Missing file parameter") catch {};
            }
        } else if (std.mem.startsWith(u8, request.path, "/tail?file=")) {
            const encoded_file_path = request.path[11..]; // Skip "/tail?file="
            // URL decode the file path
            const file_path = url.decode(arena.allocator(), encoded_file_path) catch |err| {
                std.debug.print("Error decoding URL: {s}\n", .{@errorName(err)});
                http.sendBadRequest(ctx.stream, ctx.io, "Invalid URL encoding") catch {};
                return;
            };
            tail.handleTail(ctx.io, arena.allocator(), ctx.stream, ctx.root_dir, file_path) catch |err| {
                std.debug.print("Error handling tail: {s}\n", .{@errorName(err)});
            };
        } else {
            http.sendBadRequest(ctx.stream, ctx.io, "Invalid tail endpoint") catch {};
        }
        return;
    }

    // Handle execute endpoint (shell script execution)
    if (std.mem.startsWith(u8, request.path, "/execute?file=")) {
        const file_path = request.path[14..]; // Skip "/execute?file="
        // URL decode the file path
        const decoded_file_path = url.decode(arena.allocator(), file_path) catch |err| {
            std.debug.print("Error decoding URL: {s}\n", .{@errorName(err)});
            http.sendBadRequest(ctx.stream, ctx.io, "Invalid URL encoding") catch {};
            return;
        };

        // Check for directory traversal attacks
        if (url.hasTraversal(decoded_file_path)) {
            http.sendNotFound(ctx.stream, ctx.io) catch {};
            return;
        }

        execute.handleExecute(ctx.io, arena.allocator(), ctx.stream, ctx.root_dir, decoded_file_path) catch |err| {
            std.debug.print("Error handling execute: {s}\n", .{@errorName(err)});
        };
        return;
    }

    // Handle download endpoint
    if (std.mem.startsWith(u8, request.path, "/download?file=")) {
        const file_path = request.path[15..]; // Skip "/download?file="
        // URL decode the file path
        const decoded_file_path = url.decode(arena.allocator(), file_path) catch |err| {
            std.debug.print("Error decoding URL: {s}\n", .{@errorName(err)});
            http.sendBadRequest(ctx.stream, ctx.io, "Invalid URL encoding") catch {};
            return;
        };

        // Check for directory traversal attacks
        if (url.hasTraversal(decoded_file_path)) {
            http.sendNotFound(ctx.stream, ctx.io) catch {};
            return;
        }

        file_server.serveDownload(ctx.io, ctx.stream, decoded_file_path, ctx.root_dir) catch |err| {
            std.debug.print("Error handling download: {s}\n", .{@errorName(err)});
        };
        return;
    }

    // Handle git view endpoints
    if (std.mem.eql(u8, request.path, "/__git__") or std.mem.eql(u8, request.path, "/__git__/") or
        std.mem.startsWith(u8, request.path, "/__git__?"))
    {
        // Extract optional ?path= query param (the subdirectory that is the git repo)
        const query = if (std.mem.indexOf(u8, request.path, "?")) |qi| request.path[qi + 1 ..] else "";
        const git_path_encoded = blk: {
            if (std.mem.indexOf(u8, query, "path=")) |pi| {
                const after = query[pi + 5 ..];
                const end = std.mem.indexOf(u8, after, "&") orelse after.len;
                break :blk after[0..end];
            }
            break :blk @as([]const u8, ".");
        };
        const git_path = url.decode(arena.allocator(), git_path_encoded) catch ".";
        // Sanitize: strip leading slash, reject traversal
        const safe_git_path = if (std.mem.startsWith(u8, git_path, "/")) git_path[1..] else git_path;
        if (url.hasTraversal(safe_git_path)) {
            http.sendNotFound(ctx.stream, ctx.io) catch {};
            return;
        }
        git_view.serveGitView(ctx.io, arena.allocator(), ctx.stream, ctx.root_dir, safe_git_path) catch |err| {
            std.debug.print("Error serving git view: {s}\n", .{@errorName(err)});
        };
        return;
    }

    if (std.mem.startsWith(u8, request.path, "/__git__/diff")) {
        // Extract file, untracked, and root params from query string
        const query = if (std.mem.indexOf(u8, request.path, "?")) |qi| request.path[qi + 1 ..] else "";
        const file_encoded = blk: {
            if (std.mem.indexOf(u8, query, "file=")) |fi| {
                const after = query[fi + 5 ..];
                const end = std.mem.indexOf(u8, after, "&") orelse after.len;
                break :blk after[0..end];
            }
            break :blk @as([]const u8, "");
        };
        const untracked_str = blk: {
            if (std.mem.indexOf(u8, query, "untracked=")) |ui| {
                const after = query[ui + 10 ..];
                const end = std.mem.indexOf(u8, after, "&") orelse after.len;
                break :blk after[0..end];
            }
            break :blk @as([]const u8, "0");
        };
        const root_encoded = blk: {
            if (std.mem.indexOf(u8, query, "root=")) |ri| {
                const after = query[ri + 5 ..];
                const end = std.mem.indexOf(u8, after, "&") orelse after.len;
                break :blk after[0..end];
            }
            break :blk @as([]const u8, ".");
        };
        const is_untracked = std.mem.eql(u8, untracked_str, "1");

        const file_path = url.decode(arena.allocator(), file_encoded) catch |err| {
            std.debug.print("Error decoding git diff path: {s}\n", .{@errorName(err)});
            http.sendBadRequest(ctx.stream, ctx.io, "Invalid URL encoding") catch {};
            return;
        };
        const root_path = url.decode(arena.allocator(), root_encoded) catch ".";
        const safe_root = if (std.mem.startsWith(u8, root_path, "/")) root_path[1..] else root_path;

        if (url.hasTraversal(file_path) or url.hasTraversal(safe_root)) {
            http.sendNotFound(ctx.stream, ctx.io) catch {};
            return;
        }

        git_view.serveGitDiff(ctx.io, arena.allocator(), ctx.stream, ctx.root_dir, safe_root, file_path, is_untracked) catch |err| {
            std.debug.print("Error serving git diff: {s}\n", .{@errorName(err)});
        };
        return;
    }

    if (std.mem.startsWith(u8, request.path, "/__git__/commit-diff")) {
        // Extract hash and root params from query string
        const query = if (std.mem.indexOf(u8, request.path, "?")) |qi| request.path[qi + 1 ..] else "";
        const hash_encoded = blk: {
            if (std.mem.indexOf(u8, query, "hash=")) |hi| {
                const after = query[hi + 5 ..];
                const end = std.mem.indexOf(u8, after, "&") orelse after.len;
                break :blk after[0..end];
            }
            break :blk @as([]const u8, "");
        };
        const root_encoded = blk: {
            if (std.mem.indexOf(u8, query, "root=")) |ri| {
                const after = query[ri + 5 ..];
                const end = std.mem.indexOf(u8, after, "&") orelse after.len;
                break :blk after[0..end];
            }
            break :blk @as([]const u8, ".");
        };

        const commit_hash = url.decode(arena.allocator(), hash_encoded) catch |err| {
            std.debug.print("Error decoding commit hash: {s}\n", .{@errorName(err)});
            http.sendBadRequest(ctx.stream, ctx.io, "Invalid URL encoding") catch {};
            return;
        };
        const root_path = url.decode(arena.allocator(), root_encoded) catch ".";
        const safe_root = if (std.mem.startsWith(u8, root_path, "/")) root_path[1..] else root_path;

        if (url.hasTraversal(safe_root)) {
            http.sendNotFound(ctx.stream, ctx.io) catch {};
            return;
        }

        git_view.serveCommitDiff(ctx.io, arena.allocator(), ctx.stream, ctx.root_dir, safe_root, commit_hash) catch |err| {
            std.debug.print("Error serving commit diff: {s}\n", .{@errorName(err)});
        };
        return;
    }

    // Handle git stage endpoint
    if (request.method == .POST and std.mem.startsWith(u8, request.path, "/__git__/stage")) {
        const query = if (std.mem.indexOf(u8, request.path, "?")) |qi| request.path[qi + 1 ..] else "";
        const file_encoded = blk: {
            if (std.mem.indexOf(u8, query, "file=")) |fi| {
                const after = query[fi + 5 ..];
                const end = std.mem.indexOf(u8, after, "&") orelse after.len;
                break :blk after[0..end];
            }
            break :blk @as([]const u8, "");
        };
        const root_encoded = blk: {
            if (std.mem.indexOf(u8, query, "root=")) |ri| {
                const after = query[ri + 5 ..];
                const end = std.mem.indexOf(u8, after, "&") orelse after.len;
                break :blk after[0..end];
            }
            break :blk @as([]const u8, ".");
        };

        const file_path = url.decode(arena.allocator(), file_encoded) catch |err| {
            std.debug.print("Error decoding file path: {s}\n", .{@errorName(err)});
            http.sendBadRequest(ctx.stream, ctx.io, "Invalid URL encoding") catch {};
            return;
        };
        const root_path = url.decode(arena.allocator(), root_encoded) catch ".";
        const safe_root = if (std.mem.startsWith(u8, root_path, "/")) root_path[1..] else root_path;

        if (url.hasTraversal(file_path) or url.hasTraversal(safe_root)) {
            http.sendNotFound(ctx.stream, ctx.io) catch {};
            return;
        }

        const is_root = safe_root.len == 0 or std.mem.eql(u8, safe_root, ".");
        const git_dir = if (is_root) ctx.root_dir else blk: {
            const d = ctx.root_dir.openDir(ctx.io, safe_root, .{}) catch |err| {
                std.debug.print("Failed to open git dir {s}: {s}\n", .{ safe_root, @errorName(err) });
                try http.sendErrorResponse(ctx.stream, ctx.io, .not_found, "Directory not found");
                return;
            };
            break :blk d;
        };
        defer if (!is_root) git_dir.close(ctx.io);

        const git = @import("git.zig");
        git.stageFile(ctx.io, arena.allocator(), git_dir, file_path) catch |err| {
            std.debug.print("Error staging file: {s}\n", .{@errorName(err)});
            http.sendErrorResponse(ctx.stream, ctx.io, .internal_server_error, "Failed to stage file") catch {};
            return;
        };

        try http.sendResponseHeaders(ctx.stream, ctx.io, .ok, &[_]struct { []const u8, []const u8 }{
            .{ "Content-Type", "application/json" },
        });
        var write_buf: [1024]u8 = undefined;
        var stream_writer = ctx.stream.writer(ctx.io, &write_buf);
        try stream_writer.interface.writeAll("{\"success\":true}");
        try stream_writer.interface.flush();
        return;
    }

    // Handle git unstage endpoint
    if (request.method == .POST and std.mem.startsWith(u8, request.path, "/__git__/unstage")) {
        const query = if (std.mem.indexOf(u8, request.path, "?")) |qi| request.path[qi + 1 ..] else "";
        const file_encoded = blk: {
            if (std.mem.indexOf(u8, query, "file=")) |fi| {
                const after = query[fi + 5 ..];
                const end = std.mem.indexOf(u8, after, "&") orelse after.len;
                break :blk after[0..end];
            }
            break :blk @as([]const u8, "");
        };
        const root_encoded = blk: {
            if (std.mem.indexOf(u8, query, "root=")) |ri| {
                const after = query[ri + 5 ..];
                const end = std.mem.indexOf(u8, after, "&") orelse after.len;
                break :blk after[0..end];
            }
            break :blk @as([]const u8, ".");
        };

        const file_path = url.decode(arena.allocator(), file_encoded) catch |err| {
            std.debug.print("Error decoding file path: {s}\n", .{@errorName(err)});
            http.sendBadRequest(ctx.stream, ctx.io, "Invalid URL encoding") catch {};
            return;
        };
        const root_path = url.decode(arena.allocator(), root_encoded) catch ".";
        const safe_root = if (std.mem.startsWith(u8, root_path, "/")) root_path[1..] else root_path;

        if (url.hasTraversal(file_path) or url.hasTraversal(safe_root)) {
            http.sendNotFound(ctx.stream, ctx.io) catch {};
            return;
        }

        const is_root = safe_root.len == 0 or std.mem.eql(u8, safe_root, ".");
        const git_dir = if (is_root) ctx.root_dir else blk: {
            const d = ctx.root_dir.openDir(ctx.io, safe_root, .{}) catch |err| {
                std.debug.print("Failed to open git dir {s}: {s}\n", .{ safe_root, @errorName(err) });
                try http.sendErrorResponse(ctx.stream, ctx.io, .not_found, "Directory not found");
                return;
            };
            break :blk d;
        };
        defer if (!is_root) git_dir.close(ctx.io);

        const git = @import("git.zig");
        git.unstageFile(ctx.io, arena.allocator(), git_dir, file_path) catch |err| {
            std.debug.print("Error unstaging file: {s}\n", .{@errorName(err)});
            http.sendErrorResponse(ctx.stream, ctx.io, .internal_server_error, "Failed to unstage file") catch {};
            return;
        };

        try http.sendResponseHeaders(ctx.stream, ctx.io, .ok, &[_]struct { []const u8, []const u8 }{
            .{ "Content-Type", "application/json" },
        });
        var write_buf: [1024]u8 = undefined;
        var stream_writer = ctx.stream.writer(ctx.io, &write_buf);
        try stream_writer.interface.writeAll("{\"success\":true}");
        try stream_writer.interface.flush();
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

    // Try to open as directory first (follow symlinks to support symlinked directories)
    if (ctx.root_dir.openDir(ctx.io, path_to_open, .{ .iterate = true, .follow_symlinks = true })) |dir| {
        defer dir.close(ctx.io);
        directory.listDirectory(ctx.io, arena.allocator(), ctx.stream, path_to_open, ctx.root_dir) catch |err| {
            std.debug.print("Error listing directory: {s}\n", .{@errorName(err)});
        };
        return;
    } else |_| {
        // Not a directory, try as file
        file_server.serveFile(ctx.io, arena.allocator(), ctx.stream, path_to_open, ctx.root_dir, request.headers) catch |err| {
            std.debug.print("File not found: {s} ({s})\n", .{ path_to_open, @errorName(err) });
            http.sendNotFound(ctx.stream, ctx.io) catch {};
        };
    }
}

/// Read the full request body based on Content-Length.
/// Caller must pass an allocator whose lifetime covers the returned slice;
/// using an arena allocator ensures the body is freed automatically.
fn readRequestBody(
    allocator: std.mem.Allocator,
    stream_reader: anytype,
    request: *const http.Request,
    request_raw: []const u8,
) ![]const u8 {
    // Get Content-Length header
    const content_length_str = request.headers.get("Content-Length") orelse return "";
    const content_length = std.fmt.parseInt(usize, content_length_str, 10) catch return "";

    // Check body size limit to prevent DoS attacks
    if (content_length > MAX_BODY_SIZE) {
        return error.RequestTooLarge;
    }

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

    // Allocate buffer for full body using the provided allocator
    const body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);

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

    // If we didn't read everything the stream closed early — treat as an error
    // rather than silently returning a truncated body to the upload handler.
    if (pos < content_length) {
        return error.UnexpectedEof;
    }

    return body;
}

/// Find the start of the request body (after \r\n\r\n)
fn findBodyStart(data: []const u8) ?usize {
    // Try the standard CRLF header terminator first.
    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |idx| {
        return idx + 4;
    }
    // Fall back to bare LF terminator — only 2 bytes to skip, not 4.
    if (std.mem.indexOf(u8, data, "\n\n")) |idx| {
        return idx + 2;
    }
    return null;
}
