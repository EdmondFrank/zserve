const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const url = @import("url.zig");

const BUFFER_SIZE = 4096;
const POLL_INTERVAL_MS = 500; // Check for new content every 500ms
const MAX_STREAM_DURATION_MS = 600_000; // 10 minutes max streaming duration

/// Handle tail -f request - serves an HTML page with real-time log streaming
pub fn handleTail(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    root_dir: Io.Dir,
    file_path: []const u8,
) !void {
    // Check if file exists and is readable
    const file = root_dir.openFile(io, file_path, .{}) catch |err| {
        std.debug.print("Error opening file for tail: {s}\n", .{@errorName(err)});
        try http.sendNotFound(stream, io);
        return;
    };
    defer file.close(io);

    const filename = std.fs.path.basename(file_path);

    // Build the HTML page with SSE for real-time updates
    const html = try buildTailPage(allocator, filename, file_path);
    defer allocator.free(html);

    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{html.len}) catch unreachable;

    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/html; charset=utf-8" },
        .{ "Content-Length", len_str },
        .{ "Cache-Control", "no-cache" },
    });

    var write_buf: [BUFFER_SIZE]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    try stream_writer.interface.writeAll(html);
    try stream_writer.interface.flush();
}

/// Handle SSE stream for real-time log updates
/// Uses non-blocking poll to detect client disconnect and avoid blocking the server
pub fn handleTailStream(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    root_dir: Io.Dir,
    file_path: []const u8,
) !void {
    // URL decode the path
    const decoded_path = url.decode(allocator, file_path) catch |err| {
        std.debug.print("Error decoding URL: {s}\n", .{@errorName(err)});
        try http.sendBadRequest(stream, io, "Invalid URL encoding");
        return;
    };
    defer allocator.free(decoded_path);

    // Check for directory traversal attacks
    if (url.hasTraversal(decoded_path)) {
        try http.sendNotFound(stream, io);
        return;
    }

    // Normalize path (remove leading /)
    const path = if (std.mem.startsWith(u8, decoded_path, "/"))
        decoded_path[1..]
    else
        decoded_path;

    // Open the file
    const file = root_dir.openFile(io, path, .{}) catch |err| {
        std.debug.print("Error opening file for tail stream: {s}\n", .{@errorName(err)});
        try http.sendNotFound(stream, io);
        return;
    };
    defer file.close(io);

    const file_size = try file.length(io);

    // Set socket to non-blocking mode for poll-based disconnect detection
    const sock_fd = stream.socket.handle;
    const flags = std.posix.system.fcntl(sock_fd, std.posix.F.GETFL, @as(usize, 0));
    const nonblock_flag = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = std.posix.system.fcntl(sock_fd, std.posix.F.SETFL, @as(usize, @intCast(flags)) | nonblock_flag);

    // Send SSE headers
    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/event-stream" },
        .{ "Cache-Control", "no-cache" },
        .{ "Connection", "keep-alive" },
    });

    var write_buf: [BUFFER_SIZE]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);

    // Start from the last 8192 bytes of the file (like tail -f)
    var last_size = file_size;

    // Send initial file size
    var size_buf: [64]u8 = undefined;
    const size_msg = try std.fmt.bufPrint(&size_buf, "event: info\ndata: {{\"size\": {d}}}\n\n", .{file_size});
    try stream_writer.interface.writeAll(size_msg);
    try stream_writer.interface.flush();

    // Send initial tail content (last 8192 bytes)
    if (file_size > 0) {
        const read_offset: u64 = if (file_size > 8192) file_size - 8192 else 0;
        const initial_bytes = file_size - read_offset;
        if (initial_bytes > 0) {
            var initial_buf: [8192]u8 = undefined;
            const to_read = @min(initial_bytes, initial_buf.len);
            const n = file.readPositionalAll(io, initial_buf[0..to_read], read_offset) catch |err| blk: {
                std.debug.print("Error reading initial tail content: {s}\n", .{@errorName(err)});
                break :blk 0;
            };
            if (n > 0) {
                try sendSseData(&stream_writer.interface, initial_buf[0..n]);
                try stream_writer.interface.flush();
            }
        }
    }

    // Stream loop using non-blocking poll
    var read_buf: [BUFFER_SIZE]u8 = undefined;
    var total_elapsed_ms: u64 = 0;
    var keepalive_counter: u64 = 0;

    // Prepare pollfd for client disconnect detection
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = sock_fd,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        },
    };

    while (total_elapsed_ms < MAX_STREAM_DURATION_MS) {
        // Use poll with timeout - this is NON-BLOCKING
        // Returns when: client disconnects, data arrives, or timeout
        const poll_result = std.posix.poll(&poll_fds, POLL_INTERVAL_MS) catch |err| {
            std.debug.print("Poll error: {s}\n", .{@errorName(err)});
            break;
        };

        total_elapsed_ms += POLL_INTERVAL_MS;

        // Check for client disconnect
        if (poll_result > 0) {
            const revents = poll_fds[0].revents;

            // Client disconnected (HUP) or error condition
            if ((revents & std.posix.POLL.HUP) != 0 or
                (revents & std.posix.POLL.ERR) != 0)
            {
                std.debug.print("Client disconnected from tail stream\n", .{});
                break;
            }

            // Note: POLL.IN with zero-byte read would indicate clean close,
            // but that requires libc recv(). POLL.HUP above handles most cases.
        }

        // Check current file size
        const current_size = file.length(io) catch |err| {
            std.debug.print("Error getting file size: {s}\n", .{@errorName(err)});
            break;
        };

        if (current_size > last_size) {
            // New content added - read and send it
            const new_bytes = current_size - last_size;
            var remaining = new_bytes;

            // Read in chunks to handle large additions
            while (remaining > 0) {
                const bytes_to_read = @min(remaining, BUFFER_SIZE);

                const n = file.readPositionalAll(io, read_buf[0..bytes_to_read], last_size) catch |err| {
                    std.debug.print("Error reading file: {s}\n", .{@errorName(err)});
                    break;
                };

                if (n == 0) break;

                // Send as SSE data event
                sendSseData(&stream_writer.interface, read_buf[0..n]) catch |err| {
                    std.debug.print("Error sending SSE data: {s}\n", .{@errorName(err)});
                    // Likely client disconnected
                    return;
                };
                stream_writer.interface.flush() catch {
                    // Flush failed - client likely disconnected
                    return;
                };

                last_size += n;
                remaining -= n;
            }

            last_size = current_size;
        } else if (current_size < last_size) {
            // File was truncated - reset tracking
            last_size = current_size;

            sendSseData(&stream_writer.interface, "[File truncated, resetting...]") catch return;
            stream_writer.interface.writeAll("\nevent: reset\ndata: {}\n\n") catch return;
            stream_writer.interface.flush() catch return;
        }

        // Send keepalive ping every 30 seconds
        keepalive_counter += POLL_INTERVAL_MS;
        if (keepalive_counter >= 30000) {
            keepalive_counter = 0;
            stream_writer.interface.writeAll(": keepalive\n\n") catch return;
            stream_writer.interface.flush() catch return;
        }
    }

    std.debug.print("Tail stream ended after {d}ms\n", .{total_elapsed_ms});
}

/// Send data as SSE event, handling multi-line data
fn sendSseData(writer: *Io.Writer, data: []const u8) !void {
    // Escape special SSE characters
    var lines = std.mem.splitScalar(u8, data, '\n');
    var is_first = true;

    try writer.writeAll("data: ");

    while (lines.next()) |line| {
        if (!is_first) {
            try writer.writeAll("\ndata: ");
        }
        is_first = false;

        // Escape SSE special characters
        for (line) |c| {
            switch (c) {
                '\r' => {}, // Skip carriage returns
                else => try writer.writeByte(c),
            }
        }
    }

    try writer.writeAll("\n\n");
}

/// Build the HTML page for tail -f interface
fn buildTailPage(allocator: std.mem.Allocator, filename: []const u8, file_path: []const u8) ![]const u8 {
    // URL encode the file path for SSE endpoint
    const encoded_path = try url.encode(allocator, file_path);
    defer allocator.free(encoded_path);

    const html_template =
        \\<!DOCTYPE html>
        \\<html><head>
        \\  <meta charset="utf-8">
        \\  <title>{s} - Live Tail</title>
        \\  <style>
        \\    body {{ font-family: "SF Mono", Monaco, Inconsolata, "Fira Code", monospace; background: #1a1a1a; color: #e5e5e5; min-height: 100vh; display: flex; flex-direction: column; margin: 0; }}
        \\    .header {{ background: linear-gradient(135deg, #2d3748 0%, #1a202c 100%); color: #e2e8f0; padding: 1em 2em; box-shadow: 0 2px 8px rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: space-between; flex-shrink: 0; }}
        \\    .header h1 {{ margin: 0; font-size: 1.2em; font-weight: 500; }}
        \\    .header .status {{ display: inline-flex; align-items: center; gap: 0.5em; font-size: 0.85em; padding: 0.4em 1em; background: rgba(0,0,0,0.3); border-radius: 20px; margin-top: 0.5em; }}
        \\    .header .status::before {{ content: ""; width: 8px; height: 8px; background: #48bb78; border-radius: 50%; animation: pulse 2s infinite; }}
        \\    .header .status.disconnected::before {{ background: #f56565; animation: none; }}
        \\    .header .status.paused::before {{ background: #ed8936; animation: none; }}
        \\    @keyframes pulse {{ 0%, 100% {{ opacity: 1; }} 50% {{ opacity: 0.5; }} }}
        \\    .header a {{ color: #a0aec0; text-decoration: none; padding: 0.5em 1em; background: rgba(255,255,255,0.05); border-radius: 6px; transition: all 0.2s; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; font-size: 0.9em; }}
        \\    .header a:hover {{ background: rgba(255,255,255,0.1); color: #fff; }}
        \\    .controls {{ display: flex; gap: 1em; align-items: center; }}
        \\    .btn {{ padding: 0.4em 1em; background: rgba(255,255,255,0.1); border: 1px solid rgba(255,255,255,0.2); color: #e2e8f0; border-radius: 6px; cursor: pointer; font-size: 0.85em; transition: all 0.2s; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }}
        \\    .btn:hover {{ background: rgba(255,255,255,0.2); }}
        \\    .btn.active {{ background: #3182ce; border-color: #3182ce; }}
        \\    .log-container {{ flex: 1; overflow-y: auto; padding: 1em 2em; background: #0d0d0d; }}
        \\    .log-content {{ white-space: pre-wrap; word-break: break-all; line-height: 1.6; font-size: 13px; }}
        \\    .log-line {{ padding: 2px 0; border-bottom: 1px solid rgba(255,255,255,0.03); }}
        \\    .log-line:hover {{ background: rgba(255,255,255,0.03); }}
        \\    .line-number {{ display: inline-block; width: 4em; text-align: right; margin-right: 1em; color: #4a5568; user-select: none; }}
        \\    .info-bar {{ background: rgba(45, 55, 72, 0.5); padding: 0.5em 2em; font-size: 0.8em; color: #a0aec0; border-top: 1px solid rgba(255,255,255,0.1); flex-shrink: 0; display: flex; justify-content: space-between; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }}
        \\    .log-error {{ color: #fc8181; }}
        \\    .log-warn {{ color: #f6ad55; }}
        \\    .log-info {{ color: #63b3ed; }}
        \\    .log-debug {{ color: #a0aec0; }}
        \\    .log-timestamp {{ color: #718096; }}
        \\    .scroll-indicator {{ position: fixed; bottom: 80px; right: 20px; background: #3182ce; color: white; padding: 0.5em 1em; border-radius: 20px; font-size: 0.85em; cursor: pointer; opacity: 0; transition: opacity 0.3s; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; box-shadow: 0 2px 8px rgba(0,0,0,0.3); }}
        \\    .scroll-indicator.visible {{ opacity: 1; }}
        \\  </style>
        \\</head><body>
        \\  <div class="header">
        \\    <div>
        \\      <h1>📜 {s}</h1>
        \\      <div class="status" id="status">Connected</div>
        \\    </div>
        \\    <div class="controls">
        \\      <button class="btn active" id="autoScrollBtn" onclick="toggleAutoScroll()">Auto-scroll</button>
        \\      <button class="btn" onclick="clearLogs()">Clear</button>
        \\      <a href="/">← Back</a>
        \\    </div>
        \\  </div>
        \\  <div class="log-container" id="logContainer">
        \\    <div class="log-content" id="logContent"></div>
        \\  </div>
        \\  <div class="scroll-indicator" id="scrollIndicator" onclick="scrollToBottom()">↓ New lines</div>
        \\  <div class="info-bar">
        \\    <span id="lineCount">0 lines</span>
        \\    <span>Reconnecting automatically</span>
        \\  </div>
        \\  <script>
        \\    const logContent = document.getElementById('logContent');
        \\    const logContainer = document.getElementById('logContainer');
        \\    const statusEl = document.getElementById('status');
        \\    const lineCountEl = document.getElementById('lineCount');
        \\    const scrollIndicator = document.getElementById('scrollIndicator');
        \\    const autoScrollBtn = document.getElementById('autoScrollBtn');
        \\    let eventSource = null;
        \\    let lineNumber = 0;
        \\    let autoScroll = true;
        \\    let isUserScrolling = false;
        \\    let scrollTimeout = null;
        \\    const maxLines = 5000;
        \\    logContainer.addEventListener('scroll', () => {{ if (scrollTimeout) clearTimeout(scrollTimeout); isUserScrolling = true; const nearBottom = logContainer.scrollHeight - logContainer.scrollTop - logContainer.clientHeight < 50; if (!nearBottom && autoScroll) {{ autoScroll = false; autoScrollBtn.classList.remove('active'); scrollIndicator.classList.add('visible'); }} else if (nearBottom && !autoScroll) {{ autoScroll = true; autoScrollBtn.classList.add('active'); scrollIndicator.classList.remove('visible'); }} scrollTimeout = setTimeout(() => {{ isUserScrolling = false; }}, 150); }});
        \\    function toggleAutoScroll() {{ autoScroll = !autoScroll; autoScrollBtn.classList.toggle('active'); if (autoScroll) {{ scrollToBottom(); scrollIndicator.classList.remove('visible'); }} }}
        \\    function scrollToBottom() {{ logContainer.scrollTop = logContainer.scrollHeight; autoScroll = true; autoScrollBtn.classList.add('active'); scrollIndicator.classList.remove('visible'); }}
        \\    function clearLogs() {{ logContent.innerHTML = ''; lineNumber = 0; updateLineCount(); }}
        \\    function updateLineCount() {{ lineCountEl.textContent = lineNumber + ' line' + (lineNumber !== 1 ? 's' : ''); }}
        \\    function escapeHtml(text) {{ const div = document.createElement('div'); div.textContent = text; return div.innerHTML; }}
        \\    function addLogLine(text) {{ lineNumber++; const line = document.createElement('div'); line.className = 'log-line'; let content = escapeHtml(text); if (/\\berror\\b|\\bfatal\\b|\\bcritical\\b/i.test(text)) {{ content = '<span class="log-error">' + content + '</span>'; }} else if (/\\bwarn(ing)?\\b/i.test(text)) {{ content = '<span class="log-warn">' + content + '</span>'; }} else if (/\\binfo\\b/i.test(text)) {{ content = '<span class="log-info">' + content + '</span>'; }} else if (/\\bdebug\\b/i.test(text)) {{ content = '<span class="log-debug">' + content + '</span>'; }} content = content.replace(/\\d{{4}}-\\d{{2}}-\\d{{2}}[T ]\\d{{2}}:\\d{{2}}:\\d{{2}}(\\.\\d+)?(Z|[+-]\\d{{2}}:\\d{{2}})?/g, '<span class="log-timestamp">$&</span>'); line.innerHTML = '<span class="line-number">' + lineNumber + '</span>' + content; logContent.appendChild(line); while (logContent.children.length > maxLines) {{ logContent.removeChild(logContent.firstChild); }} updateLineCount(); if (autoScroll) {{ logContainer.scrollTop = logContainer.scrollHeight; }} }}
        \\    function connect() {{ if (eventSource) {{ eventSource.close(); }} eventSource = new EventSource('/tail/stream?file={s}'); eventSource.onopen = () => {{ statusEl.textContent = 'Connected'; statusEl.classList.remove('disconnected', 'paused'); }}; eventSource.onmessage = (event) => {{ const lines = event.data.split('\\n'); lines.forEach(line => {{ if (line.trim()) addLogLine(line); }}); }}; eventSource.onerror = () => {{ statusEl.textContent = 'Disconnected - Reconnecting...'; statusEl.classList.add('disconnected'); eventSource.close(); setTimeout(connect, 2000); }}; }}
        \\    document.addEventListener('visibilitychange', () => {{ if (document.hidden) {{ statusEl.textContent = 'Paused'; statusEl.classList.add('paused'); }} else {{ statusEl.classList.remove('paused'); }} }});
        \\    connect();
        \\  </script>
        \\</body></html>
    ;

    return try std.fmt.allocPrint(allocator, html_template, .{
        filename, filename, encoded_path,
    });
}
