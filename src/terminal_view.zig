const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");

/// Serve the terminal HTML page.
/// The page loads wterm from npm/CDN and connects a WebSocket to the terminal endpoint.
pub fn serveTerminalPage(
    io: Io,
    stream: Io.net.Stream,
) !void {
    const html =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\  <title>Terminal - ZServe</title>
        \\  <style>
        \\    * { margin: 0; padding: 0; box-sizing: border-box; }
        \\    html, body { height: 100%; overflow: hidden; background: #1e1e2e; }
        \\    .terminal-bar {
        \\      background: linear-gradient(135deg, #3b82f6 0%, #2563eb 100%);
        \\      color: white;
        \\      padding: 0.5em 1em;
        \\      display: flex;
        \\      align-items: center;
        \\      justify-content: space-between;
        \\      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        \\      font-size: 0.85em;
        \\      flex-shrink: 0;
        \\      box-shadow: 0 2px 8px rgba(0,0,0,0.3);
        \\    }
        \\    .terminal-bar .left { display: flex; align-items: center; gap: 0.5em; }
        \\    .terminal-bar a {
        \\      color: white;
        \\      text-decoration: none;
        \\      padding: 0.3em 0.8em;
        \\      background: rgba(255,255,255,0.15);
        \\      border-radius: 6px;
        \\      transition: background 0.2s;
        \\      font-size: 0.9em;
        \\    }
        \\    .terminal-bar a:hover { background: rgba(255,255,255,0.25); }
        \\    .status-indicator {
        \\      display: inline-flex;
        \\      align-items: center;
        \\      gap: 0.4em;
        \\      padding: 0.2em 0.7em;
        \\      background: rgba(0,0,0,0.2);
        \\      border-radius: 20px;
        \\      font-size: 0.85em;
        \\    }
        \\    .status-indicator::before {
        \\      content: "";
        \\      width: 8px;
        \\      height: 8px;
        \\      border-radius: 50%;
        \\      background: #48bb78;
        \\      animation: pulse 2s infinite;
        \\    }
        \\    .status-indicator.disconnected::before { background: #f56565; animation: none; }
        \\    .status-indicator.connecting::before { background: #ed8936; animation: none; }
        \\    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
        \\    #terminal-container {
        \\      height: calc(100vh - 38px);
        \\      width: 100vw;
        \\      overflow: hidden;
        \\    }
        \\    /* wterm theme overrides */
        \\    .wterm {
        \\      --wterm-bg: #1e1e2e;
        \\      --wterm-fg: #cdd6f4;
        \\      --wterm-font-family: "SF Mono", Monaco, Inconsolata, "Fira Code", monospace;
        \\      --wterm-font-size: 14px;
        \\    }
        \\  </style>
        \\  <!-- Load wterm vanilla JS from CDN -->
        \\  <script type="importmap">
        \\  {
        \\    "imports": {
        \\      "@wterm/dom": "https://esm.sh/@wterm/dom@latest"
        \\    }
        \\  }
        \\  </script>
        \\</head>
        \\<body>
        \\  <div class="terminal-bar">
        \\    <div class="left">
        \\      <span>🖥️ ZServe Terminal</span>
        \\      <span class="status-indicator connecting" id="status">Connecting...</span>
        \\    </div>
        \\    <a href="/">← Back to Files</a>
        \\  </div>
        \\  <div id="terminal-container"></div>
        \\
        \\  <script type="module">
        \\    import { WTerm, WebSocketTransport } from "@wterm/dom";
        \\
        \\    const statusEl = document.getElementById('status');
        \\    const container = document.getElementById('terminal-container');
        \\
        \\    // Determine WebSocket URL from current page URL
        \\    const wsProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        \\    const wsUrl = `${wsProtocol}//${window.location.host}/__terminal__/ws`;
        \\
        \\    // Create the terminal
        \\    const term = new WTerm(container, {
        \\      cols: 80,
        \\      rows: 24,
        \\      autoResize: true,
        \\      cursorBlink: true,
        \\      onData(data) {
        \\        // Send user input to the WebSocket
        \\        ws.send(data);
        \\      },
        \\      onResize(cols, rows) {
        \\        // Send resize message to server
        \\        ws.send(JSON.stringify({ cols, rows }));
        \\      }
        \\    });
        \\
        \\    // Initialize the terminal (loads WASM)
        \\    await term.init();
        \\
        \\    // Create WebSocket transport
        \\    const ws = new WebSocketTransport({
        \\      url: wsUrl,
        \\      reconnect: true,
        \\      maxReconnectDelay: 5000,
        \\      onData(data) {
        \\        // Write server output to terminal
        \\        term.write(data);
        \\      },
        \\      onOpen() {
        \\        statusEl.textContent = 'Connected';
        \\        statusEl.className = 'status-indicator';
        \\      },
        \\      onClose() {
        \\        statusEl.textContent = 'Disconnected - Reconnecting...';
        \\        statusEl.className = 'status-indicator disconnected';
        \\      },
        \\      onError() {
        \\        statusEl.textContent = 'Error';
        \\        statusEl.className = 'status-indicator disconnected';
        \\      }
        \\    });
        \\
        \\    ws.connect();
        \\    term.focus();
        \\  </script>
        \\</body>
        \\</html>
    ;

    // Build Content-Length
    var len_buf: [16]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{html.len}) catch unreachable;

    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/html; charset=utf-8" },
        .{ "Content-Length", len_str },
        .{ "Cache-Control", "no-cache" },
    });

    var write_buf: [16384]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    try stream_writer.interface.writeAll(html);
    try stream_writer.interface.flush();
}
