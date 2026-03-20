# Markdown Preview Module

This module provides a beautiful, GitHub-style Markdown preview with table of contents, dark mode support, and toggle between rendered and source views.

## Features

- **Client-side rendering** using marked.js CDN
- **GitHub-style Markdown styling** with responsive layout
- **Table of contents** sidebar generated from headings
- **Light/Dark mode** with CSS variables (matches directory.zig theme)
- **Syntax highlighting** via highlight.js (15+ languages)
- **View toggle** between rendered and source views
- **Back to directory** button in header
- **File metadata** display (size, mime type)
- **Mobile-responsive** with collapsible sidebar

## Usage

### 1. Add to handler.zig

Import the markdown module:

```zig
const markdown = @import("markdown.zig");
```

### 2. Integrate into request handler

Modify the file serving logic in `handler.zig` to check for Markdown files and render them as HTML:

```zig
// In handleConnection, before serving as raw file:

// Check if it's a Markdown file
const is_markdown = std.mem.endsWith(u8, path, ".md") or 
                    std.mem.endsWith(u8, path, ".markdown");

if (is_markdown) {
    // Read the file content
    const file = ctx.root_dir.openFile(ctx.io, path_to_open, .{}) catch |err| {
        http.sendNotFound(ctx.stream, ctx.io) catch {};
        return;
    };
    defer file.close(ctx.io);
    
    const file_size = file.length(ctx.io) catch 0;
    const content = file.readToEndAlloc(arena.allocator(), file_size) catch |err| {
        std.debug.print("Error reading file: {s}\n", .{@errorName(err)});
        http.sendNotFound(ctx.stream, ctx.io) catch {};
        return;
    };
    
    // Get directory path for "back" link
    const dir_path = std.fs.path.dirname(path) orelse ".";
    
    // Render as HTML preview
    markdown.renderMarkdownPreview(
        ctx.io,
        arena.allocator(),
        ctx.stream,
        path,
        dir_path,
        content,
        file_size,
    ) catch |err| {
        std.debug.print("Error rendering markdown: {s}\n", .{@errorName(err)});
        http.sendNotFound(ctx.stream, ctx.io) catch {};
    };
    return;
}
```

### 3. Template Format String

The `markdown_preview_template` constant uses these format placeholders:

| Placeholder | Description | Example |
|-------------|-------------|---------|
| `{0s}` | Page title (filename) | `README.md` |
| `{1s}` | Parent directory URL | `/docs` or `/` |
| `{2s}` | Filename display | `README.md` |
| `{3s}` | File size string | `12.5 KB` |
| `{4s}` | MIME type | `text/markdown` |
| `{5s}` | Raw markdown (JS-escaped) | `# Hello\\n\\nWorld` |

## Example Integration Code

Here's a complete example for `handler.zig`:

```zig
const std = @import("std");
const Io = std.Io;
const url = @import("url.zig");
const http = @import("http.zig");
const directory = @import("directory.zig");
const file_server = @import("file_server.zig");
const markdown = @import("markdown.zig");

pub fn handleConnection(ctx: ConnectionContext) !void {
    // ... existing code ...
    
    // Try to open as directory first
    if (ctx.root_dir.openDir(ctx.io, path_to_open, .{ .iterate = true })) |dir| {
        defer dir.close(ctx.io);
        directory.listDirectory(ctx.io, arena.allocator(), ctx.stream, path_to_open, ctx.root_dir) catch |err| {
            std.debug.print("Error listing directory: {s}\n", .{@errorName(err)});
        };
        return;
    } else |_| {
        // Not a directory, check if it's a markdown file
        const is_markdown = std.mem.endsWith(u8, path, ".md") or 
                            std.mem.endsWith(u8, path, ".markdown");
        
        if (is_markdown) {
            // Serve as HTML preview
            const file = ctx.root_dir.openFile(ctx.io, path_to_open, .{}) catch |err| {
                std.debug.print("File not found: {s} ({s})\n", .{ path_to_open, @errorName(err) });
                http.sendNotFound(ctx.stream, ctx.io) catch {};
                return;
            };
            defer file.close(ctx.io);
            
            const file_size = file.length(ctx.io) catch 0;
            const content = file.readToEndAlloc(arena.allocator(), file_size) catch |err| {
                std.debug.print("Error reading file: {s}\n", .{@errorName(err)});
                http.sendNotFound(ctx.stream, ctx.io) catch {};
                return;
            };
            
            const dir_path = std.fs.path.dirname(path) orelse ".";
            
            markdown.renderMarkdownPreview(
                ctx.io,
                arena.allocator(),
                ctx.stream,
                path,
                dir_path,
                content,
                file_size,
            ) catch |err| {
                std.debug.print("Error rendering markdown: {s}\n", .{@errorName(err)});
                http.sendNotFound(ctx.stream, ctx.io) catch {};
            };
            return;
        }
        
        // Not markdown, serve as regular file
        file_server.serveFile(ctx.io, arena.allocator(), ctx.stream, path_to_open, ctx.root_dir, request.headers) catch |err| {
            std.debug.print("File not found: {s} ({s})\n", .{ path_to_open, @errorName(err) });
            http.sendNotFound(ctx.stream, ctx.io) catch {};
        };
    }
}
```

## CDN Dependencies

The template loads these CDN resources:

| Resource | URL | Purpose |
|----------|-----|---------|
| marked.js | `https://cdn.jsdelivr.net/npm/marked/marked.min.js` | Markdown parsing |
| highlight.js CSS | `https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css` | Code styling (light) |
| highlight.js CSS (dark) | `https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css` | Code styling (dark) |
| highlight.js | `https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js` | Syntax highlighting |

Language-specific highlighters loaded:
- bash, zig, rust, go, python, javascript, typescript, json, yaml, xml, css, sql

## Styling

The CSS uses CSS variables that match the directory listing theme:

```css
:root {
  --bg-color: #ffffff;
  --text-color: #24292e;
  --link-color: #0366d6;
  --header-gradient-start: #3b82f6;
  --header-gradient-end: #2563eb;
  /* ... more variables */
}
```

The header uses the same blue gradient as the directory listing upload form.

## JavaScript Features

- **TOC Generation**: Automatically creates table of contents from H1-H6 headings
- **Active Section Highlighting**: Updates TOC as user scrolls
- **View Toggle**: Switch between rendered and source views (persists in localStorage)
- **Theme Toggle**: Switch between light and dark modes (persists in localStorage)
- **Mobile Sidebar**: Floating toggle button on small screens

## Security Considerations

- Markdown content is escaped for JavaScript string embedding
- HTML special characters are escaped in filenames
- Uses marked.js's built-in sanitization (disabled for full GitHub-style support - content is trusted from local filesystem)
