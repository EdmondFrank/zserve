const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");

/// Magic GUID defined by RFC 6455 for WebSocket handshake
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// WebSocket opcodes (RFC 6455 §5.2)
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

/// A parsed WebSocket frame from the client
pub const Frame = struct {
    opcode: Opcode,
    data: []const u8,
};

/// Perform the WebSocket upgrade handshake.
/// Sends back the HTTP 101 Switching Protocols response with the computed
/// Sec-WebSocket-Accept header.
pub fn doHandshake(
    stream: Io.net.Stream,
    io: Io,
    request: *const http.Request,
) !void {
    // Get the client's WebSocket key
    const ws_key = request.headers.get("Sec-WebSocket-Key") orelse return error.MissingWebSocketKey;

    // Compute the accept value: base64(SHA-1(key + GUID))
    var concat_buf: [256]u8 = undefined;
    if (ws_key.len + WS_GUID.len > concat_buf.len) return error.WebSocketKeyTooLong;
    @memcpy(concat_buf[0..ws_key.len], ws_key);
    @memcpy(concat_buf[ws_key.len .. ws_key.len + WS_GUID.len], WS_GUID);
    const concat = concat_buf[0 .. ws_key.len + WS_GUID.len];

    var sha1_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(concat, &sha1_hash, .{});

    var accept_buf: [32]u8 = undefined;
    const accept_value = std.base64.standard.Encoder.encode(&accept_buf, &sha1_hash);

    // Send the 101 Switching Protocols response
    var write_buf: [1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    const w = &stream_writer.interface;

    try w.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try w.writeAll("Upgrade: websocket\r\n");
    try w.writeAll("Connection: Upgrade\r\n");
    try w.writeAll("Sec-WebSocket-Accept: ");
    try w.writeAll(accept_value);
    try w.writeAll("\r\n\r\n");
    try w.flush();
}

/// Read a single WebSocket frame from the stream.
/// The returned data slice points into `payload_buf`.
/// Note: fragmentation across multiple frames is not reassembled;
/// each call returns one frame. The FIN bit is parsed but not acted upon.
pub fn readFrame(
    stream: Io.net.Stream,
    io: Io,
    header_buf: *[2]u8,
    len_buf: *[8]u8,
    mask_buf: *[4]u8,
    payload_buf: []u8,
) !Frame {
    // Read the first 2 bytes of the frame header
    var read_buf: [128]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    const r = &stream_reader.interface;

    // Byte 0: FIN(1) | RSV(3) | Opcode(4)
    {
        var w = Io.Writer.fixed(header_buf[0..1]);
        _ = try r.stream(&w, .limited(1));
    }
    const fin = (header_buf[0] & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(header_buf[0] & 0x0F);

    // Byte 1: MASK(1) | Payload length(7)
    {
        var w = Io.Writer.fixed(header_buf[1..2]);
        _ = try r.stream(&w, .limited(1));
    }
    const masked = (header_buf[1] & 0x80) != 0;
    var payload_len: u64 = header_buf[1] & 0x7F;

    // Extended payload length (16-bit or 64-bit)
    if (payload_len == 126) {
        var w = Io.Writer.fixed(len_buf[0..2]);
        _ = try r.stream(&w, .limited(2));
        payload_len = (@as(u64, len_buf[0]) << 8) | @as(u64, len_buf[1]);
    } else if (payload_len == 127) {
        var w = Io.Writer.fixed(len_buf[0..8]);
        _ = try r.stream(&w, .limited(8));
        payload_len = 0;
        for (len_buf[0..8]) |b| {
            payload_len = (payload_len << 8) | b;
        }
    }

    if (payload_len > payload_buf.len) return error.PayloadTooLarge;

    // Read masking key (clients must mask frames)
    if (masked) {
        var w = Io.Writer.fixed(mask_buf[0..4]);
        _ = try r.stream(&w, .limited(4));
    }

    // Read payload
    if (payload_len > 0) {
        var w = Io.Writer.fixed(payload_buf[0..@intCast(payload_len)]);
        _ = try r.stream(&w, .limited(@intCast(payload_len)));
    }

    // Unmask the payload
    if (masked and payload_len > 0) {
        for (payload_buf[0..@intCast(payload_len)], 0..) |*byte, i| {
            byte.* ^= mask_buf[i % 4];
        }
    }

    _ = fin; // We don't currently handle fragmentation across reads
    return Frame{
        .opcode = opcode,
        .data = payload_buf[0..@intCast(payload_len)],
    };
}

/// Write a WebSocket frame (text or binary) to the stream.
/// Server-to-client frames are not masked (per RFC 6455 §5.3).
pub fn writeFrame(
    stream: Io.net.Stream,
    io: Io,
    opcode: Opcode,
    data: []const u8,
) !void {
    // Build the frame header
    var header: [10]u8 = undefined;
    header[0] = @as(u8, 0x80) | @as(u8, @intFromEnum(opcode)); // FIN=1 + opcode

    var header_len: usize = 0;
    if (data.len <= 125) {
        header[1] = @intCast(data.len);
        header_len = 2;
    } else if (data.len <= 65535) {
        header[1] = 126;
        header[2] = @intCast((data.len >> 8) & 0xFF);
        header[3] = @intCast(data.len & 0xFF);
        header_len = 4;
    } else {
        header[1] = 127;
        header[2] = 0;
        header[3] = 0;
        header[4] = 0;
        header[5] = 0;
        header[6] = @intCast((data.len >> 24) & 0xFF);
        header[7] = @intCast((data.len >> 16) & 0xFF);
        header[8] = @intCast((data.len >> 8) & 0xFF);
        header[9] = @intCast(data.len & 0xFF);
        header_len = 10;
    }

    // Write header + data using a single buffered writer when data fits,
    // or write header first then data in chunks for large payloads.
    if (data.len <= 3500) {
        // Small enough: header + data fit in one write buffer
        var write_buf: [4096]u8 = undefined;
        var stream_writer = stream.writer(io, &write_buf);
        try stream_writer.interface.writeAll(header[0..header_len]);
        if (data.len > 0) {
            try stream_writer.interface.writeAll(data);
        }
        try stream_writer.interface.flush();
    } else {
        // Large payload: write header first, then data separately
        var header_buf: [16]u8 = undefined;
        var header_writer = stream.writer(io, &header_buf);
        try header_writer.interface.writeAll(header[0..header_len]);
        try header_writer.interface.flush();

        var data_buf: [8192]u8 = undefined;
        var data_writer = stream.writer(io, &data_buf);
        try data_writer.interface.writeAll(data);
        try data_writer.interface.flush();
    }
}

/// Send a close frame and flush.
pub fn sendClose(stream: Io.net.Stream, io: Io) !void {
    try writeFrame(stream, io, .close, &[_]u8{});
}

/// Send a ping frame.
pub fn sendPing(stream: Io.net.Stream, io: Io) !void {
    try writeFrame(stream, io, .ping, &[_]u8{});
}
