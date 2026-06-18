# AGENTS.md

This document provides guidance for AI agents working with this codebase.

## Project Overview

Local Server is a lightweight HTTP file server written in Zig 0.16. It serves static files and provides directory listings with a web interface.

## Build Commands

```bash
# Build the project
zig build

# Run tests
zig build test

# Run the server
zig build run -- --root . --port 8080

# Build with optimizations
zig build -Doptimize=ReleaseFast

# Run the server with web terminal enabled
zig build run -- --root . --port 8080 --terminal
```

## Code Architecture

### Module Structure

The codebase is organized into modular components:

| Module | Purpose |
|--------|---------|
| `main.zig` | Entry point, server initialization, connection loop |
| `handler.zig` | HTTP connection handling, request routing |
| `http.zig` | HTTP protocol parsing, response generation |
| `directory.zig` | Directory listing HTML generation |
| `file_server.zig` | File serving with Range request support |
| `markdown.zig` | Markdown preview rendering |
| `ooxml_preview.zig` | Office Open XML preview (DOCX, XLSX, PPTX) |
| `legacy_preview.zig` | Legacy Office preview (DOC, XLS, PPT) |
| `pdf_preview.zig` | PDF preview via zpdf text extraction |
| `url.zig` | URL encoding/decoding, path normalization |
| `mime_types.zig` | MIME type detection from file extensions |
| `logger.zig` | Request logging utilities |
| `params.zig` | CLI argument parsing |
| `server_context.zig` | Server state management |
| `websocket.zig` | WebSocket protocol (RFC 6455) handshake, frame read/write |
| `pty.zig` | Pseudo-terminal allocation (posix_openpt, fork, login_tty) |
| `terminal.zig` | Terminal session relay (WebSocket ↔ PTY bidirectional) |
| `terminal_view.zig` | Terminal HTML page generator (loads wterm from CDN) |

### Data Flow

```
main.zig
    │
    ├── params.parseArgs() → Parse CLI arguments
    │
    ├── Io.net.IpAddress.listen() → Create server socket
    │
    └── Loop: server.accept()
            │
            └── handler.handleConnection()
                    │
                    ├── http.parseRequest() → Parse HTTP request
                    │
                    ├── url.decode() → Decode URL path
                    │
                    ├── url.hasTraversal() → Security check
                    │
                    ├── root_dir.openDir() → Try as directory
                    │       │
                    │       └── directory.listDirectory() → HTML listing
                    │
                    └── root_dir.openFile() → Try as file
                            │
                            └── file_server.serveFile() → Send file
```

## Zig 0.16 API Notes

This project uses the new Zig 0.16 I/O API. Key differences from earlier versions:

### I/O Types
- `std.fs` → `std.Io` for file operations
- `std.net` → `std.Io.net` for networking
- `std.Thread.Mutex` → `std.Io.Mutex`

### File Operations
- `File.getEndPos()` → `File.length(io)`
- `File.seekTo()` → Use positional reads: `File.readPositional(io, buffer, offset)`
- `Dir.openDir()` requires `io` parameter: `dir.openDir(io, path, options)`

### Networking
- `net.Address` → `Io.net.IpAddress`
- `address.listen()` → `address.listen(io, options)`
- `server.accept()` → `server.accept(io)`
- Stream I/O uses Reader/Writer with buffers:
  ```zig
  var buf: [4096]u8 = undefined;
  var stream_reader = stream.reader(io, &buf);
  var stream_writer = stream.writer(io, &buf);
  ```

### Memory Management
- `ArrayList.init(allocator)` → `ArrayList.initCapacity(allocator, n)`
- `ArrayList.append(item)` → `ArrayList.append(allocator, item)`
- `ArrayList.appendSlice(items)` → `ArrayList.appendSlice(allocator, items)`
- `ArrayList.deinit()` → `ArrayList.deinit(allocator)`

### Main Function
```zig
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    // ...
}
```

## Common Tasks

### Adding a New MIME Type

Edit `src/mime_types.zig`:

```zig
if (std.mem.eql(u8, ext, ".xyz")) return "application/x-xyz";
```

### Adding a New HTTP Status Code

Edit `src/http.zig`, add to `StatusCode` enum:

```zig
pub const StatusCode = enum(u16) {
    ok = 200,
    // ... existing codes
    new_status = 999,
    
    pub fn toText(self: StatusCode) []const u8 {
        return switch (self) {
            // ... existing cases
            .new_status => "New Status",
        };
    }
};
```

### Adding a New CLI Option

1. Edit `src/params.zig`:
   - Add field to `Args` struct
   - Add parsing logic in `parseArgs()`
   - Update `printHelp()` function

2. Use the new option in `src/main.zig`

### Web Terminal (wterm Integration)

The web terminal feature provides an interactive shell accessible via the browser using [wterm](https://wterm.dev/) — a Zig/WASM terminal emulator.

**Enabling**: Use the `--terminal` CLI flag. Disabled by default for security.

```
zig build run -- --root . --port 8080 --terminal
```

**Architecture**:

```
Browser (wterm DOM)  ←──WebSocket──→  ZServe  ←──PTY──→  /bin/sh
```

- `/__terminal__` — Serves the terminal HTML page (loads wterm JS from CDN)
- `/__terminal__/ws` — WebSocket upgrade endpoint, spawns PTY and relays data

**Key modules**:

- `websocket.zig` — RFC 6455 WebSocket handshake (SHA-1 + base64 accept), frame parser (opcode, mask, payload length), frame encoder
- `pty.zig` — PTY allocation via `posix_openpt` → `grantpt` → `unlockpt` → `ptsname` → `fork` → `login_tty`
- `terminal.zig` — Bidirectional relay loop using `poll()`, handles resize messages (JSON `{"cols":N,"rows":N}`)
- `terminal_view.zig` — HTML page with wterm vanilla JS, WebSocketTransport, auto-resize

**Security**: Terminal grants full shell access. Only enable on trusted networks. The server defaults to `127.0.0.1` binding.

## Testing

Tests are located in `src/tests/`. Each module has a corresponding test file:

- `test_url.zig` - URL encoding/decoding tests
- `test_http.zig` - HTTP parsing tests
- `test_mime_types.zig` - MIME type detection tests

Run all tests:
```bash
zig build test
```

## Error Handling

The server handles errors gracefully:
- File not found → 404 response
- Invalid requests → 400 response
- Internal errors → 500 response
- Connection errors → Logged and connection closed

## Security Considerations

1. **Path Traversal**: The `url.hasTraversal()` function blocks requests containing `..`
2. **URL Encoding**: All URLs are decoded before use
3. **Path Normalization**: Leading slashes are stripped from paths

## Performance Notes

- Uses arena allocators for per-request allocations
- Buffers I/O operations (64KB buffer for file transfers)
- Supports Range requests for efficient media streaming
- Single-threaded by default (can be extended with thread pool)
