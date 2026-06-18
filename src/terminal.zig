const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const websocket = @import("websocket.zig");
const pty = @import("pty.zig");

/// Buffer sizes for relay
const WS_PAYLOAD_SIZE: usize = 65536;
const PTY_READ_SIZE: usize = 65536;
const POLL_TIMEOUT_MS: i32 = 1000;

/// Handle a WebSocket terminal session.
/// This function:
/// 1. Completes the WebSocket handshake
/// 2. Spawns a PTY with the given working directory
/// 3. Relays data bidirectionally between the WebSocket and PTY
/// 4. Handles resize messages (JSON: {"cols":N,"rows":N})
/// 5. Cleans up on disconnect
pub fn handleTerminalSession(
    io: Io,
    stream: Io.net.Stream,
    request: *const http.Request,
    cwd: []const u8,
) !void {
    // 1. WebSocket handshake
    websocket.doHandshake(stream, io, request) catch |err| {
        std.debug.print("WebSocket handshake failed: {s}\n", .{@errorName(err)});
        return;
    };

    // 2. Spawn PTY
    var proc = pty.spawn(cwd) catch |err| {
        std.debug.print("PTY spawn failed: {s}\n", .{@errorName(err)});
        websocket.sendClose(stream, io) catch {};
        return;
    };
    defer proc.kill();

    std.debug.print("Terminal session started (pid: {d})\n", .{proc.child_pid});

    // 3. Bidirectional relay using poll
    var ws_payload_buf: [WS_PAYLOAD_SIZE]u8 = undefined;
    var pty_read_buf: [PTY_READ_SIZE]u8 = undefined;
    var header_buf: [2]u8 = undefined;
    var len_buf: [8]u8 = undefined;
    var mask_buf: [4]u8 = undefined;

    const sock_fd = stream.socket.handle;
    const master_fd = proc.master_fd;

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = sock_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = master_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var running = true;
    while (running) {
        const poll_result = std.posix.poll(&poll_fds, POLL_TIMEOUT_MS) catch |err| {
            std.debug.print("Terminal poll error: {s}\n", .{@errorName(err)});
            break;
        };

        if (poll_result == 0) continue; // timeout, loop again

        // Check WebSocket → PTY direction
        if (poll_fds[0].revents != 0) {
            const revents = poll_fds[0].revents;
            if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                std.debug.print("WebSocket client disconnected\n", .{});
                break;
            }

            if ((revents & std.posix.POLL.IN) != 0) {
                // Read a frame from the WebSocket
                const frame = websocket.readFrame(
                    stream,
                    io,
                    &header_buf,
                    &len_buf,
                    &mask_buf,
                    &ws_payload_buf,
                ) catch |err| {
                    std.debug.print("WebSocket read error: {s}\n", .{@errorName(err)});
                    running = false;
                    break;
                };

                switch (frame.opcode) {
                    .text, .binary => {
                        // Check if this is a resize message (JSON)
                        if (frame.data.len > 0 and frame.data[0] == '{') {
                            if (handleResizeMessage(frame.data, proc)) {
                                // Was a resize message, don't send to PTY
                                continue;
                            }
                        }
                        // Write data to the PTY
                        _ = proc.write(frame.data) catch {
                            std.debug.print("PTY write failed\n", .{});
                            running = false;
                            break;
                        };
                    },
                    .close => {
                        std.debug.print("WebSocket close received\n", .{});
                        running = false;
                        break;
                    },
                    .ping => {
                        // Respond with pong
                        websocket.writeFrame(stream, io, .pong, frame.data) catch {};
                    },
                    else => {},
                }
            }
        }

        // Check PTY → WebSocket direction
        if (poll_fds[1].revents != 0) {
            const revents = poll_fds[1].revents;
            if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                std.debug.print("PTY process exited\n", .{});
                break;
            }

            if ((revents & std.posix.POLL.IN) != 0) {
                const n = proc.read(&pty_read_buf) catch |err| {
                    std.debug.print("PTY read error: {s}\n", .{@errorName(err)});
                    running = false;
                    break;
                };

                if (n == 0) {
                    std.debug.print("PTY process closed\n", .{});
                    break;
                }

                // Send PTY output to WebSocket as binary frame
                websocket.writeFrame(stream, io, .binary, pty_read_buf[0..n]) catch |err| {
                    std.debug.print("WebSocket write error: {s}\n", .{@errorName(err)});
                    running = false;
                    break;
                };
            }
        }
    }

    // Send close frame
    websocket.sendClose(stream, io) catch {};

    std.debug.print("Terminal session ended\n", .{});
}

/// Try to parse a resize message from the WebSocket data.
/// Expected format: {"cols":80,"rows":24}
/// Returns true if the message was a resize command.
fn handleResizeMessage(data: []const u8, proc: pty.PtyProcess) bool {
    // Simple JSON parsing without a full parser
    const cols = extractJsonInt(data, "cols") orelse return false;
    const rows = extractJsonInt(data, "rows") orelse return false;

    if (cols == 0 or rows == 0) return false;
    if (cols > 1000 or rows > 1000) return false;

    proc.resize(@intCast(cols), @intCast(rows)) catch |err| {
        std.debug.print("PTY resize failed: {s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

/// Extract an integer value from a simple JSON string by key.
/// Looks for "key":value pattern.
fn extractJsonInt(data: []const u8, key: []const u8) ?u64 {
    var needle_buf: [128]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1 .. key.len + 1], key);
    needle_buf[key.len + 1] = '"';
    needle_buf[key.len + 2] = ':';
    const needle = needle_buf[0 .. key.len + 3];

    const idx = std.mem.indexOf(u8, data, needle) orelse return null;
    const val_start = idx + needle.len;

    // Skip whitespace
    var i = val_start;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}

    // Parse digits
    var result: u64 = 0;
    var has_digit = false;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        result = result * 10 + (data[i] - '0');
        has_digit = true;
    }

    return if (has_digit) result else null;
}
