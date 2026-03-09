const std = @import("std");
const Io = std.Io;
const url = @import("url.zig");

const DirEntry = struct {
    name: []const u8,
    kind: Io.File.Kind,
    size: u64,

    fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
        if (a.kind == .directory and b.kind != .directory) return true;
        if (a.kind != .directory and b.kind == .directory) return false;
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

/// List a directory and send an HTML response
pub fn listDirectory(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    dir_path: []const u8,
    root_dir: Io.Dir,
) !void {
    var dir = try root_dir.openDir(io, dir_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer dir.close(io);

    var list = std.ArrayList(DirEntry).initCapacity(allocator, 64) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    defer {
        for (list.items) |entry| {
            allocator.free(entry.name);
        }
    }

    // Collect all entries with file sizes
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const size = if (entry.kind == .file) size_blk: {
            const full_path = if (dir_path.len == 0 or std.mem.eql(u8, dir_path, "."))
                entry.name
            else
                try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer if (dir_path.len > 0 and !std.mem.eql(u8, dir_path, ".")) allocator.free(full_path);

            const file = root_dir.openFile(io, full_path, .{}) catch break :size_blk 0;
            defer file.close(io);
            break :size_blk file.length(io) catch 0;
        } else 0;

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
            .size = size,
        });
    }

    // Sort entries (directories first, then alphabetically)
    std.mem.sort(DirEntry, list.items, {}, DirEntry.lessThan);

    // Create stream writer
    var write_buf: [65536]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);

    // Send HTTP response headers
    try stream_writer.interface.writeAll("HTTP/1.1 200 OK\r\n");
    try stream_writer.interface.writeAll("Content-Type: text/html; charset=utf-8\r\n");
    try stream_writer.interface.writeAll("\r\n");

    // Send HTML header
    try stream_writer.interface.writeAll(
        \\<html><head>
        \\  <meta charset="utf-8">
        \\  <style>
        \\    body { font-family: sans-serif; margin: 2em; }
        \\    .directory { font-weight: bold; color: #0366d6; }
        \\    .file { color: #24292e; }
        \\    ul { list-style-type: none; padding: 0; }
        \\    li { margin: 0.5em 0; display: flex; align-items: center; padding: 0.4em 0.8em; border-radius: 8px; transition: background-color 0.2s; }
        \\    li:hover { background-color: #e5e7eb; }
        \\    li a { flex: 1; text-decoration: none; }
        \\    .size { color: #666; margin-left: 1em; min-width: 6em; text-align: right; }
        \\    a:hover { text-decoration: underline; }
        \\    .upload-form { margin: 1.5em 0; padding: 1.5em; background: linear-gradient(135deg, #f8fafc 0%, #f1f5f9 100%); border-radius: 12px; border: 1px solid #e2e8f0; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        \\    .upload-form form { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
        \\    .file-input-wrapper { position: relative; display: inline-block; }
        \\    .file-input-wrapper input[type="file"] { position: absolute; opacity: 0; width: 100%; height: 100%; cursor: pointer; }
        \\    .file-input-label { display: inline-flex; align-items: center; gap: 8px; padding: 10px 18px; background: #fff; border: 2px dashed #cbd5e1; border-radius: 8px; color: #64748b; font-size: 14px; cursor: pointer; transition: all 0.2s; }
        \\    .file-input-wrapper:hover .file-input-label { border-color: #3b82f6; color: #3b82f6; background: #eff6ff; }
        \\    .file-input-label::before { content: "📎"; font-size: 16px; }
        \\    .upload-btn { display: inline-flex; align-items: center; gap: 8px; padding: 10px 20px; background: linear-gradient(135deg, #3b82f6 0%, #2563eb 100%); color: white; border: none; border-radius: 8px; font-size: 14px; font-weight: 500; cursor: pointer; transition: all 0.2s; box-shadow: 0 2px 4px rgba(37, 99, 235, 0.3); }
        \\    .upload-btn:hover { transform: translateY(-1px); box-shadow: 0 4px 8px rgba(37, 99, 235, 0.4); }
        \\    .upload-btn:active { transform: translateY(0); }
        \\    .upload-btn::before { content: "⬆️"; font-size: 14px; }
        \\    .file-name { color: #334155; font-size: 14px; margin-left: 8px; }
        \\    .delete-btn { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: #fee2e2; border: 1px solid #fecaca; border-radius: 6px; color: #dc2626; font-size: 14px; cursor: pointer; transition: all 0.2s; margin-left: 8px; }
        \\    .delete-btn:hover { background: #fecaca; transform: scale(1.05); }
        \\    .delete-btn:active { transform: scale(0.95); }
        \\    .tail-btn { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: #dbeafe; border: 1px solid #bfdbfe; border-radius: 6px; color: #2563eb; font-size: 14px; cursor: pointer; transition: all 0.2s; margin-left: 8px; }
        \\    .tail-btn:hover { background: #bfdbfe; transform: scale(1.05); }
        \\    .tail-btn:active { transform: scale(0.95); }
        \\    .exec-btn { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: #dcfce7; border: 1px solid #bbf7d0; border-radius: 6px; color: #16a34a; font-size: 14px; cursor: pointer; transition: all 0.2s; margin-left: 8px; }
        \\    .exec-btn:hover { background: #bbf7d0; transform: scale(1.05); }
        \\    .exec-btn:active { transform: scale(0.95); }
        \\  </style>
        \\  <script>
        \\    function confirmDelete(filename, path, isDirectory) {
        \\      const itemType = isDirectory ? 'directory' : 'file';
        \\      const warningMsg = isDirectory 
        \\        ? 'WARNING: This will delete the entire directory and ALL its contents!' 
        \\        : '';
        \\      if (!confirm('Are you sure you want to delete ' + itemType + ' "' + filename + '"?\n\n' + warningMsg)) {
        \\        return;
        \\      }
        \\      fetch('/' + path, { method: 'DELETE' })
        \\        .then(response => {
        \\          if (response.ok) {
        \\            window.location.reload();
        \\          } else {
        \\            alert('Failed to delete ' + itemType);
        \\          }
        \\        })
        \\        .catch(err => {
        \\          alert('Error: ' + err.message);
        \\        });
        \\    }
        \\    function confirmExecute(filename, path) {
        \\      if (!confirm('Are you sure you want to execute "' + filename + '"?\n\nWARNING: This will run the script on the server!')) {
        \\        return;
        \\      }
        \\      fetch('/execute?file=' + encodeURIComponent(path), { method: 'POST' })
        \\        .then(response => response.text())
        \\        .then(html => {
        \\          document.open();
        \\          document.write(html);
        \\          document.close();
        \\        })
        \\        .catch(err => {
        \\          alert('Error: ' + err.message);
        \\        });
        \\    }
        \\  </script>
        \\</head><body>
        \\<h1>Directory listing:
    );

    const title = if (dir_path.len == 0) "/" else dir_path;
    try stream_writer.interface.writeAll(title);
    try stream_writer.interface.writeAll("</h1>\n");

    // Add upload form with pretty button
    try stream_writer.interface.writeAll(
        \\  <div class="upload-form">
        \\    <form action="/upload" method="post" enctype="multipart/form-data" id="uploadForm">
    );
    // Add hidden field with current directory path
    if (!std.mem.eql(u8, dir_path, ".")) {
        try stream_writer.interface.writeAll("      <input type=\"hidden\" name=\"path\" value=\"");
        // Escape HTML special chars in the path
        for (dir_path) |c| {
            switch (c) {
                '&' => try stream_writer.interface.writeAll("&amp;"),
                '<' => try stream_writer.interface.writeAll("&lt;"),
                '"' => try stream_writer.interface.writeAll("&quot;"),
                else => try stream_writer.interface.writeByte(c),
            }
        }
        try stream_writer.interface.writeAll("\" />\n");
    }
    try stream_writer.interface.writeAll(
        \\      <div class="file-input-wrapper">
        \\        <input type="file" name="file" id="fileInput" required onchange="document.getElementById('fileName').textContent=this.files[0]?this.files[0].name:''" />
        \\        <label for="fileInput" class="file-input-label">Choose file</label>
        \\      </div>
        \\      <span id="fileName" class="file-name"></span>
        \\      <button type="submit" class="upload-btn">Upload</button>
        \\    </form>
        \\  </div>
        \\<ul>
    );

    // Add parent directory link if not at root
    if (!std.mem.eql(u8, dir_path, ".")) {
        try stream_writer.interface.writeAll("<li><a href=\"..\" class=\"directory\">..</a><span class=\"size\">-</span></li>\n");
    }

    // List all entries
    for (list.items) |entry| {
        try sendDirEntry(&stream_writer.interface, allocator, entry, dir_path);
    }

    // Send HTML footer
    try stream_writer.interface.writeAll("</ul></body></html>");
    try stream_writer.interface.flush();
}

fn sendDirEntry(
    writer: *Io.Writer,
    allocator: std.mem.Allocator,
    entry: DirEntry,
    dir_path: []const u8,
) !void {
    const class = if (entry.kind == .directory) "directory" else "file";
    const encoded_name = try url.encode(allocator, entry.name);
    defer allocator.free(encoded_name);

    try writer.writeAll("<li><a href=\"/");

    if (!std.mem.eql(u8, dir_path, ".")) {
        try writer.writeAll(dir_path);
        try writer.writeAll("/");
    }
    try writer.writeAll(encoded_name);

    try writer.writeAll("\" class=\"");
    try writer.writeAll(class);
    try writer.writeAll("\">");

    // Write display name (escape HTML special chars)
    for (entry.name) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }

    if (entry.kind == .directory) {
        try writer.writeAll("/");
    }

    try writer.writeAll("</a><span class=\"size\">");

    // Format size
    if (entry.kind == .directory) {
        try writer.writeAll("-");
    } else {
        try formatSize(writer, entry.size);
    }

    try writer.writeAll("</span>");

    // Add delete button for all entries (files and directories)
    // Build full path for delete
    const full_path = if (std.mem.eql(u8, dir_path, "."))
        entry.name
    else
        try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
    defer if (!std.mem.eql(u8, dir_path, ".")) allocator.free(full_path);

    // Escape the filename for JavaScript
    try writer.writeAll("<button class=\"delete-btn\" onclick=\"confirmDelete('");
    // Escape single quotes in filename for JS
    for (entry.name) |c| {
        switch (c) {
            '\\', '\'' => {
                try writer.writeByte('\\');
                try writer.writeByte(c);
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("', '");
    // Escape single quotes in path for JS
    for (full_path) |c| {
        switch (c) {
            '\\', '\'' => {
                try writer.writeByte('\\');
                try writer.writeByte(c);
            },
            else => try writer.writeByte(c),
        }
    }
    const is_dir = entry.kind == .directory;
    if (is_dir) {
        try writer.writeAll("', true)\" title=\"Delete directory\">🗑️</button>");
    } else {
        try writer.writeAll("', false)\" title=\"Delete file\">🗑️</button>");

        // Add Tail button for text files
        if (!is_dir and isTextFile(entry.name)) {
            try writer.writeAll("<button class=\"tail-btn\" onclick=\"window.open('/tail?file=");
            // Escape the path for URL
            const url_encoded_path = try url.encode(allocator, full_path);
            defer allocator.free(url_encoded_path);
            try writer.writeAll(url_encoded_path);
            try writer.writeAll("', '_blank')\" title=\"Tail -f\">📜</button>");
        }

        // Add Execute button for shell scripts
        if (!is_dir and isShellScript(entry.name)) {
            try writer.writeAll("<button class=\"exec-btn\" onclick=\"confirmExecute('");
            // Escape single quotes in filename for JS
            for (entry.name) |c| {
                switch (c) {
                    '\\', '\'' => {
                        try writer.writeByte('\\');
                        try writer.writeByte(c);
                    },
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeAll("', '");
            // Escape single quotes in path for JS
            for (full_path) |c| {
                switch (c) {
                    '\\', '\'' => {
                        try writer.writeByte('\\');
                        try writer.writeByte(c);
                    },
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeAll("')\" title=\"Execute script\">▶️</button>");
        }
    }

    try writer.writeAll("</li>\n");
}

/// Check if a file is likely a text/log file based on extension
fn isTextFile(filename: []const u8) bool {
    const text_extensions = &[_][]const u8{
        ".txt",        ".log",      ".md",    ".csv",    ".json",       ".yaml",   ".yml",
        ".toml",       ".ini",      ".conf",  ".config", ".properties", ".sh",     ".bash",
        ".zsh",        ".fish",     ".ps1",   ".bat",    ".cmd",        ".js",     ".ts",
        ".jsx",        ".tsx",      ".vue",   ".html",   ".htm",        ".css",    ".scss",
        ".sass",       ".less",     ".styl",  ".py",     ".rb",         ".pl",     ".php",
        ".java",       ".kt",       ".scala", ".go",     ".rs",         ".c",      ".cpp",
        ".cc",         ".cxx",      ".h",     ".hpp",    ".cs",         ".fs",     ".fsx",
        ".vb",         ".swift",    ".zig",   ".c3",     ".odin",       ".v",      ".nim",
        ".r",          ".m",        ".mm",    ".groovy", ".clj",        ".cljs",   ".hs",
        ".lhs",        ".elm",      ".erl",   ".hrl",    ".ex",         ".exs",    ".lua",
        ".moon",       ".cr",       ".d",     ".dlang",  ".jl",         ".pas",    ".pp",
        ".inc",        ".ml",       ".mli",   ".sml",    ".sql",        ".sqlite", ".pgsql",
        ".mysql",      ".xml",      ".svg",   ".xsl",    ".xslt",       ".xsd",    ".dtd",
        ".dockerfile", ".makefile", ".cmake", ".gradle",
    };

    // Convert filename to lowercase for case-insensitive comparison
    var lower_buf: [256]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buf, filename);

    for (text_extensions) |ext| {
        if (std.mem.endsWith(u8, lower, ext)) {
            return true;
        }
    }

    // Special case for files without extension that are commonly text files
    const special_files = &[_][]const u8{
        "dockerfile",    "makefile",     "rakefile",      "gemfile",
        "cargo.toml",    "package.json", "composer.json", "readme",
        "license",       "changelog",    "authors",       ".gitignore",
        ".dockerignore", ".env",         ".editorconfig",
    };

    for (special_files) |name| {
        if (std.mem.eql(u8, lower, name)) {
            return true;
        }
    }

    return false;
}

/// Check if a file is a shell script based on extension
fn isShellScript(filename: []const u8) bool {
    const shell_extensions = &[_][]const u8{
        ".sh", ".bash", ".zsh", ".fish", ".ksh",
    };

    // Convert filename to lowercase for case-insensitive comparison
    var lower_buf: [256]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buf, filename);

    for (shell_extensions) |ext| {
        if (std.mem.endsWith(u8, lower, ext)) {
            return true;
        }
    }
    return false;
}

fn formatSize(writer: *Io.Writer, size: u64) !void {
    if (size < 1024) {
        try writer.print("{d} B", .{size});
    } else if (size < 1024 * 1024) {
        try writer.print("{d:.1} KB", .{@as(f64, @floatFromInt(size)) / 1024});
    } else if (size < 1024 * 1024 * 1024) {
        try writer.print("{d:.1} MB", .{@as(f64, @floatFromInt(size)) / (1024 * 1024)});
    } else {
        try writer.print("{d:.1} GB", .{@as(f64, @floatFromInt(size)) / (1024 * 1024 * 1024)});
    }
}
