const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");

/// Serve the terminal HTML page.
/// Uses Solarized Dark theme with full UX: auto-scroll, scroll-to-bottom
/// button, themed scrollbar, title bar updates, reconnect overlay.
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
        \\  <title>Terminal — ZServe</title>
        \\  <style>
        \\    /* ── Solarized Dark palette ── */
        \\    :root {
        \\      --base03: #002b36;
        \\      --base02: #073642;
        \\      --base01: #586e75;
        \\      --base00: #657b83;
        \\      --base0:  #839496;
        \\      --base1:  #93a1a1;
        \\      --base2:  #eee8d5;
        \\      --base3:  #fdf6e3;
        \\      --yellow: #b58900;
        \\      --orange: #cb4b16;
        \\      --red:    #dc322f;
        \\      --magenta:#d33682;
        \\      --violet: #6c71c4;
        \\      --blue:   #268bd2;
        \\      --cyan:   #2aa198;
        \\      --green:  #859900;
        \\      --mono: "SF Mono", "JetBrains Mono", "Fira Code", Menlo, Consolas, "DejaVu Sans Mono", monospace;
        \\      --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
        \\    }
        \\
        \\    * { margin: 0; padding: 0; box-sizing: border-box; }
        \\    html, body { height: 100%; overflow: hidden; }
        \\
        \\    body {
        \\      background: var(--base03);
        \\      display: flex;
        \\      flex-direction: column;
        \\    }
        \\
        \\    /* ── Top bar ── */
        \\    .topbar {
        \\      background: var(--base02);
        \\      border-bottom: 1px solid var(--base01);
        \\      padding: 0 1rem;
        \\      height: 40px;
        \\      display: flex;
        \\      align-items: center;
        \\      justify-content: space-between;
        \\      flex-shrink: 0;
        \\      font-family: var(--sans);
        \\      font-size: 13px;
        \\      color: var(--base1);
        \\      user-select: none;
        \\    }
        \\    .topbar-left { display: flex; align-items: center; gap: 0.75rem; }
        \\    .topbar-right { display: flex; align-items: center; gap: 0.5rem; }
        \\    .topbar .icon { font-size: 16px; line-height: 1; }
        \\    .topbar .title { font-weight: 600; color: var(--base2); letter-spacing: 0.02em; }
        \\    .topbar .divider { width: 1px; height: 16px; background: var(--base01); }
        \\
        \\    /* Status pill */
        \\    .status {
        \\      display: inline-flex;
        \\      align-items: center;
        \\      gap: 0.4em;
        \\      padding: 0.15em 0.6em;
        \\      border-radius: 20px;
        \\      font-size: 11px;
        \\      font-weight: 500;
        \\      letter-spacing: 0.03em;
        \\      background: var(--base03);
        \\      border: 1px solid var(--base01);
        \\      color: var(--base0);
        \\      transition: all 0.3s ease;
        \\    }
        \\    .status .dot {
        \\      width: 7px; height: 7px; border-radius: 50%;
        \\      background: var(--green);
        \\      animation: pulse 2.5s ease-in-out infinite;
        \\    }
        \\    .status.connecting { border-color: var(--yellow); color: var(--yellow); }
        \\    .status.connecting .dot { background: var(--yellow); animation: none; }
        \\    .status.disconnected { border-color: var(--orange); color: var(--orange); }
        \\    .status.disconnected .dot { background: var(--orange); animation: none; }
        \\    .status.error { border-color: var(--red); color: var(--red); }
        \\    .status.error .dot { background: var(--red); animation: none; }
        \\    @keyframes pulse {
        \\      0%, 100% { opacity: 1; }
        \\      50% { opacity: 0.35; }
        \\    }
        \\
        \\    /* Back button */
        \\    .btn-back {
        \\      display: inline-flex; align-items: center; gap: 0.35em;
        \\      padding: 0.3em 0.7em;
        \\      border-radius: 6px;
        \\      color: var(--base1);
        \\      text-decoration: none;
        \\      font-size: 12px;
        \\      transition: all 0.2s;
        \\      border: 1px solid transparent;
        \\    }
        \\    .btn-back:hover {
        \\      background: var(--base03);
        \\      border-color: var(--base01);
        \\      color: var(--base2);
        \\    }
        \\
        \\    /* ── Terminal area ── */
        \\    #terminal-wrap {
        \\      flex: 1;
        \\      position: relative;
        \\      overflow: hidden;
        \\    }
        \\    #terminal-container {
        \\      width: 100%;
        \\      height: 100%;
        \\      overflow: hidden;
        \\    }
        \\
        \\    /* wterm internal scroll container */
        \\    .wterm {
        \\      width: 100%;
        \\      height: 100%;
        \\    }
        \\    /* Style the scrollable area inside wterm */
        \\    .wterm-scroll {
        \\      overflow-y: auto !important;
        \\      scrollbar-width: thin;
        \\      scrollbar-color: var(--base01) transparent;
        \\    }
        \\    .wterm-scroll::-webkit-scrollbar { width: 8px; }
        \\    .wterm-scroll::-webkit-scrollbar-track { background: transparent; }
        \\    .wterm-scroll::-webkit-scrollbar-thumb {
        \\      background: var(--base01);
        \\      border-radius: 4px;
        \\    }
        \\    .wterm-scroll::-webkit-scrollbar-thumb:hover {
        \\      background: var(--base00);
        \\    }
        \\
        \\    /* ── Scroll-to-bottom button ── */
        \\    .scroll-btn {
        \\      position: absolute;
        \\      bottom: 1rem;
        \\      right: 1.25rem;
        \\      width: 36px;
        \\      height: 36px;
        \\      border-radius: 50%;
        \\      background: var(--base02);
        \\      border: 1px solid var(--base01);
        \\      color: var(--base1);
        \\      display: flex;
        \\      align-items: center;
        \\      justify-content: center;
        \\      cursor: pointer;
        \\      font-size: 18px;
        \\      opacity: 0;
        \\      pointer-events: none;
        \\      transition: opacity 0.25s ease, transform 0.25s ease, background 0.2s;
        \\      z-index: 20;
        \\      transform: translateY(8px);
        \\    }
        \\    .scroll-btn.visible {
        \\      opacity: 1;
        \\      pointer-events: auto;
        \\      transform: translateY(0);
        \\    }
        \\    .scroll-btn:hover {
        \\      background: var(--base01);
        \\      color: var(--base2);
        \\      border-color: var(--base00);
        \\    }
        \\
        \\    /* Loading overlay */
        \\    .loader {
        \\      position: absolute; inset: 0;
        \\      display: flex; flex-direction: column;
        \\      align-items: center; justify-content: center;
        \\      gap: 1rem;
        \\      background: var(--base03);
        \\      z-index: 10;
        \\      transition: opacity 0.4s ease;
        \\    }
        \\    .loader.hidden { opacity: 0; pointer-events: none; }
        \\    .loader .spinner {
        \\      width: 32px; height: 32px;
        \\      border: 2px solid var(--base02);
        \\      border-top-color: var(--cyan);
        \\      border-radius: 50%;
        \\      animation: spin 0.8s linear infinite;
        \\    }
        \\    @keyframes spin { to { transform: rotate(360deg); } }
        \\    .loader .label {
        \\      font-family: var(--mono);
        \\      font-size: 12px;
        \\      color: var(--base01);
        \\      letter-spacing: 0.05em;
        \\    }
        \\
        \\    /* ── Reconnect overlay ── */
        \\    .reconnect-overlay {
        \\      position: absolute; inset: 0;
        \\      display: none;
        \\      flex-direction: column;
        \\      align-items: center; justify-content: center;
        \\      gap: 1rem;
        \\      background: rgba(0, 43, 54, 0.92);
        \\      backdrop-filter: blur(4px);
        \\      z-index: 15;
        \\    }
        \\    .reconnect-overlay.visible { display: flex; }
        \\    .reconnect-overlay .msg {
        \\      font-family: var(--sans);
        \\      font-size: 14px;
        \\      color: var(--base1);
        \\    }
        \\    .reconnect-overlay .btn-reconnect {
        \\      padding: 0.5em 1.2em;
        \\      border-radius: 6px;
        \\      background: var(--blue);
        \\      color: var(--base3);
        \\      border: none;
        \\      font-family: var(--sans);
        \\      font-size: 13px;
        \\      font-weight: 600;
        \\      cursor: pointer;
        \\      transition: background 0.2s;
        \\    }
        \\    .reconnect-overlay .btn-reconnect:hover {
        \\      background: var(--cyan);
        \\    }
        \\
        \\    /* ── wterm Solarized Dark theme ── */
        \\    .wterm {
        \\      --term-bg: #002b36;
        \\      --term-fg: #93a1a1;
        \\      --term-cursor: #eee8d5;
        \\      --term-font-family: "SF Mono", "JetBrains Mono", "Fira Code", Menlo, Consolas, monospace;
        \\      --term-font-size: 14px;
        \\      --term-line-height: 1.3;
        \\      --term-color-0:  #073642;
        \\      --term-color-1:  #dc322f;
        \\      --term-color-2:  #859900;
        \\      --term-color-3:  #b58900;
        \\      --term-color-4:  #268bd2;
        \\      --term-color-5:  #d33682;
        \\      --term-color-6:  #2aa198;
        \\      --term-color-7:  #eee8d5;
        \\      --term-color-8:  #002b36;
        \\      --term-color-9:  #cb4b16;
        \\      --term-color-10: #586e75;
        \\      --term-color-11: #657b83;
        \\      --term-color-12: #839496;
        \\      --term-color-13: #6c71c4;
        \\      --term-color-14: #93a1a1;
        \\      --term-color-15: #fdf6e3;
        \\    }
        \\    /* Ensure wterm internal elements inherit text color */
        \\    .wterm, .wterm * {
        \\      color: #93a1a1;
        \\    }
        \\  </style>
        \\  <script type="importmap">
        \\  {
        \\    "imports": {
        \\      "@wterm/dom": "https://esm.sh/@wterm/dom@latest"
        \\    }
        \\  }
        \\  </script>
        \\</head>
        \\<body>
        \\  <div class="topbar">
        \\    <div class="topbar-left">
        \\      <span class="icon">🖥️</span>
        \\      <span class="title">Terminal</span>
        \\      <span class="divider"></span>
        \\      <span class="status connecting" id="status">
        \\        <span class="dot"></span>
        \\        <span id="status-text">Connecting</span>
        \\      </span>
        \\    </div>
        \\    <div class="topbar-right">
        \\      <a href="/" class="btn-back">← Files</a>
        \\    </div>
        \\  </div>
        \\  <div id="terminal-wrap">
        \\    <div id="terminal-container"></div>
        \\    <div class="loader" id="loader">
        \\      <div class="spinner"></div>
        \\      <div class="label">Initializing terminal…</div>
        \\    </div>
        \\    <button class="scroll-btn" id="scroll-btn" title="Scroll to bottom">↓</button>
        \\    <div class="reconnect-overlay" id="reconnect-overlay">
        \\      <div class="msg">Connection lost</div>
        \\      <button class="btn-reconnect" id="btn-reconnect">Reconnect</button>
        \\    </div>
        \\  </div>
        \\
        \\  <script type="module">
        \\    import { WTerm, WebSocketTransport } from "@wterm/dom";
        \\
        \\    const statusEl    = document.getElementById('status');
        \\    const statusText  = document.getElementById('status-text');
        \\    const loader      = document.getElementById('loader');
        \\    const container   = document.getElementById('terminal-container');
        \\    const scrollBtn   = document.getElementById('scroll-btn');
        \\    const reconnectOverlay = document.getElementById('reconnect-overlay');
        \\    const btnReconnect = document.getElementById('btn-reconnect');
        \\
        \\    // ── Auto-scroll state ──
        \\    let autoScroll = true;
        \\    let scrollEl = null;  // wterm's internal scroll element
        \\
        \\    function setStatus(cls, text) {
        \\      statusEl.className = 'status ' + cls;
        \\      statusText.textContent = text;
        \\    }
        \\
        \\    // ── Find wterm's scrollable element after init ──
        \\    function findScrollElement() {
        \\      // wterm creates a .wterm root with internal scroll containers
        \\      // Try common selectors
        \\      const candidates = [
        \\        container.querySelector('.wterm-scroll'),
        \\        container.querySelector('[class*="scroll"]'),
        \\        container.querySelector('.wterm'),
        \\      ];
        \\      for (const el of candidates) {
        \\        if (el && (el.scrollHeight > el.clientHeight || el.style.overflowY !== 'hidden')) {
        \\          return el;
        \\        }
        \\      }
        \\      // Fallback: any element that can scroll
        \\      const all = container.querySelectorAll('div');
        \\      for (const el of all) {
        \\        if (el.scrollHeight > el.clientHeight && el.clientHeight > 0) {
        \\          return el;
        \\        }
        \\      }
        \\      return container;
        \\    }
        \\
        \\    function isAtBottom() {
        \\      if (!scrollEl) return true;
        \\      return scrollEl.scrollHeight - scrollEl.scrollTop - scrollEl.clientHeight < 5;
        \\    }
        \\
        \\    function scrollToBottom() {
        \\      if (scrollEl) {
        \\        scrollEl.scrollTop = scrollEl.scrollHeight;
        \\      }
        \\      autoScroll = true;
        \\      scrollBtn.classList.remove('visible');
        \\    }
        \\
        \\    function updateScrollState() {
        \\      if (!scrollEl) return;
        \\      if (isAtBottom()) {
        \\        autoScroll = true;
        \\        scrollBtn.classList.remove('visible');
        \\      } else {
        \\        autoScroll = false;
        \\        scrollBtn.classList.add('visible');
        \\      }
        \\    }
        \\
        \\    // Determine WebSocket URL
        \\    const wsProtocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
        \\    const urlParams = new URLSearchParams(location.search);
        \\    const pathParam = urlParams.get('path');
        \\    const pathQuery = pathParam ? '?path=' + encodeURIComponent(pathParam) : '';
        \\    const wsUrl = `${wsProtocol}//${location.host}/__terminal__/ws${pathQuery}`;
        \\
        \\    // Create terminal
        \\    const term = new WTerm(container, {
        \\      cols: 80,
        \\      rows: 24,
        \\      autoResize: true,
        \\      cursorBlink: true,
        \\      onData(data) {
        \\        ws.send(data);
        \\      },
        \\      onTitle(title) {
        \\        document.title = title + ' — ZServe Terminal';
        \\      },
        \\      onResize(cols, rows) {
        \\        ws.send(JSON.stringify({ cols, rows }));
        \\      },
        \\    });
        \\
        \\    // Apply Solarized Dark theme
        \\    term.element.classList.add('theme-solarized-dark');
        \\
        \\    // Initialize (loads WASM) — hides loader when done
        \\    await term.init();
        \\    loader.classList.add('hidden');
        \\
        \\    // Find the scrollable element inside wterm
        \\    scrollEl = findScrollElement();
        \\    if (scrollEl) {
        \\      scrollEl.addEventListener('scroll', updateScrollState);
        \\    }
        \\
        \\    // Scroll button click
        \\    scrollBtn.addEventListener('click', () => {
        \\      scrollToBottom();
        \\      term.focus();
        \\    });
        \\
        \\    // ── Keyboard shortcuts ──
        \\    container.addEventListener('keydown', (e) => {
        \\      // Ctrl+Shift+C: copy selection (browser default, but ensure focus returns)
        \\      // Ctrl+L: clear screen (send escape sequence)
        \\      if (e.ctrlKey && e.key === 'l') {
        \\        e.preventDefault();
        \\        ws.send('\x1b[H\x1b[2J\x1b[3J');
        \\      }
        \\    });
        \\
        \\    // ── WebSocket transport ──
        \\    let ws;
        \\    let reconnectAttempts = 0;
        \\    let manualClose = false;
        \\
        \\    function connectWS() {
        \\      ws = new WebSocket(wsUrl);
        \\      ws.binaryType = 'arraybuffer';
        \\
        \\      ws.onopen = () => {
        \\        reconnectAttempts = 0;
        \\        setStatus('', 'Connected');
        \\        reconnectOverlay.classList.remove('visible');
        \\        // Send initial terminal size immediately
        \\        const cols = term.cols || 80;
        \\        const rows = term.rows || 24;
        \\        ws.send(JSON.stringify({ cols, rows }));
        \\        term.focus();
        \\      };
        \\
        \\      ws.onmessage = (event) => {
        \\        let data = event.data instanceof ArrayBuffer
        \\          ? new Uint8Array(event.data)
        \\          : event.data;
        \\        // Fix double-newline: strip \r when followed by \n
        \\        if (data instanceof Uint8Array) {
        \\          const out = [];
        \\          for (let i = 0; i < data.length; i++) {
        \\            if (data[i] === 0x0d && i + 1 < data.length && data[i + 1] === 0x0a) continue;
        \\            out.push(data[i]);
        \\          }
        \\          data = new Uint8Array(out);
        \\        } else if (typeof data === 'string') {
        \\          data = data.replace(/\r\n/g, '\n');
        \\        }
        \\        term.write(data);
        \\        // Auto-scroll after writing data
        \\        if (autoScroll) {
        \\          requestAnimationFrame(() => scrollToBottom());
        \\        }
        \\      };
        \\
        \\      ws.onclose = () => {
        \\        if (manualClose) return;
        \\        setStatus('disconnected', 'Disconnected');
        \\        reconnectOverlay.classList.add('visible');
        \\        // Auto-reconnect with backoff
        \\        reconnectAttempts++;
        \\        const delay = Math.min(1000 * Math.pow(2, reconnectAttempts - 1), 10000);
        \\        setTimeout(() => {
        \\          if (!manualClose) connectWS();
        \\        }, delay);
        \\      };
        \\
        \\      ws.onerror = () => {
        \\        setStatus('error', 'Error');
        \\      };
        \\    }
        \\
        \\    // Manual reconnect button
        \\    btnReconnect.addEventListener('click', () => {
        \\      reconnectAttempts = 0;
        \\      if (ws) { manualClose = true; ws.close(); manualClose = false; }
        \\      setStatus('connecting', 'Connecting');
        \\      reconnectOverlay.classList.remove('visible');
        \\      connectWS();
        \\    });
        \\
        \\    // Start connection
        \\    connectWS();
        \\    term.focus();
        \\
        \\    // Cleanup on page unload
        \\    window.addEventListener('beforeunload', () => {
        \\      manualClose = true;
        \\      if (ws) ws.close();
        \\    });
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
