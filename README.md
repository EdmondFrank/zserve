# zserve

A fast, feature-rich HTTP file server written in Zig. Serves static files with a clean web interface and a growing set of developer-focused tools.

## Features

### Core
- 🚀 **Fast and lightweight** — Built with Zig for optimal performance
- 📁 **Directory listings** — Clean HTML interface with file sizes, sorted output, and symlink resolution
- 📄 **Static file serving** — Proper MIME type detection for common file types
- 📡 **Range requests** — Partial content support for video/audio streaming and resumable downloads
- 🔒 **Security** — Path traversal protection and URL encoding validation
- 🌙 **Dark mode** — Theme toggle persisted to `localStorage`
- ⚡ **Thread pool** — Concurrent connections with DoS protection

### File Management
- 📤 **File upload** — Upload files via browser drag-and-drop or file picker
- 🗑️ **File deletion** — Delete individual files or bulk-delete multiple files with confirmation
- ⬇️ **File download** — One-click download button for any file
- ✂️ **Log truncation** — Truncate large log files in-place with confirmation

### Previews
- 📝 **Markdown preview** — Rendered preview with table of contents, syntax highlighting, and dark mode
- 🔍 **JSON / YAML / TOML preview** — Syntax-highlighted structured data preview
- 📺 **Log streaming** — Live `tail -f`-style streaming for text/log files

### Developer Tools
- ▶️ **Script execution** — Execute shell scripts directly from the browser with output display
- 🌿 **Git integration** — Full Git status view accessible at `/__git__/`

## Git Integration

Navigate to `/__git__/` (or `/__git__?path=<subdir>`) from any directory listing to open the Git view:

| Feature | Description |
|---------|-------------|
| **Status view** | Staged and unstaged changes shown in a sidebar, separated by section |
| **File diff** | Click any file to load its diff in the main panel |
| **Stage file** | `+` button stages an unstaged file (`git add`) |
| **Unstage file** | `−` button unstages a staged file (`git reset HEAD`) |
| **Restore file** | `↩` button discards working-tree changes for a file (`git restore`) with a confirmation dialog |
| **Commit history** | Expandable recent commits panel; click any commit to view its full diff |

## Requirements

- Zig 0.16.0 or later

## Building

```bash
# Build the project
zig build

# Run tests
zig build test

# Build with optimizations
zig build -Doptimize=ReleaseFast
```

## Usage

```bash
# Show help
./zig-out/bin/zserve --help

# Serve current directory on default port (8080)
./zig-out/bin/zserve --root .

# Serve with custom port
./zig-out/bin/zserve --root . --port 9000

# Serve on all interfaces (public access)
./zig-out/bin/zserve --root /var/www --host 0.0.0.0 --port 8080

# Short options
./zig-out/bin/zserve --root . -p 9000 -H 0.0.0.0
```

## Command Line Options

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `--root` | | Root directory to serve (required) | — |
| `--port` | `-p` | Port to listen on | `8080` |
| `--host` | `-H` | Host address to bind to | `127.0.0.1` |
| `--help` | `-h` | Show help message | — |

## Examples

### Development Server
```bash
# Serve a React/Vue/Angular build folder
./zig-out/bin/zserve --root ./dist --port 3000
```

### File Sharing
```bash
# Share files on local network
./zig-out/bin/zserve --root ./shared --host 0.0.0.0 --port 8000
```

### Media Streaming
```bash
# Serve video files (supports Range requests)
./zig-out/bin/zserve --root ./videos --port 8080
```

### Log Monitoring
```bash
# Serve a log directory and tail files live in the browser
./zig-out/bin/zserve --root /var/log --port 8080
```

## Project Structure

```
zserve/
├── build.zig              # Build configuration
├── src/
│   ├── main.zig           # Entry point and server setup
│   ├── handler.zig        # HTTP request routing
│   ├── http.zig           # HTTP protocol utilities
│   ├── directory.zig      # Directory listing generation
│   ├── file_server.zig    # File serving with Range support
│   ├── upload.zig         # File upload handling
│   ├── delete.zig         # File/directory deletion
│   ├── tail.zig           # Live log streaming (tail -f)
│   ├── truncate.zig       # Log file truncation
│   ├── execute.zig        # Shell script execution
│   ├── markdown.zig       # Markdown rendering
│   ├── git.zig            # Git command wrappers
│   ├── git_view.zig       # Git status/diff HTML view
│   ├── thread_pool.zig    # Concurrent connection pool
│   ├── url.zig            # URL encoding/decoding
│   ├── mime_types.zig     # MIME type detection
│   ├── logger.zig         # Request logging
│   ├── params.zig         # CLI argument parsing
│   ├── server_context.zig # Server state management
│   └── tests/
│       ├── test_url.zig
│       ├── test_http.zig
│       └── test_mime_types.zig
└── README.md
```

## Supported MIME Types

### Text
- HTML (`.html`, `.htm`), CSS (`.css`), JavaScript (`.js`), Plain text (`.txt`)

### Images
- JPEG (`.jpg`, `.jpeg`), PNG (`.png`), WebP (`.webp`), AVIF (`.avif`), GIF (`.gif`), SVG (`.svg`)

### Video
- MP4 (`.mp4`), WebM (`.webm`), MKV (`.mkv`)

### Audio
- MP3 (`.mp3`), WAV (`.wav`), OGG (`.ogg`)

### Documents & Data
- PDF (`.pdf`), ZIP (`.zip`), JSON (`.json`), YAML (`.yaml`, `.yml`), TOML (`.toml`), Markdown (`.md`)

Other file types are served as `application/octet-stream`.

## Security

- **Path traversal** — Requests containing `..` are rejected before any filesystem access
- **URL encoding** — Malformed URL encodings are handled safely
- **Upload size limit** — Request bodies capped at 10 MB to prevent DoS
- **Script execution** — Requires explicit user confirmation in the browser before running

## License

MIT License

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `zig build test`
5. Submit a pull request
