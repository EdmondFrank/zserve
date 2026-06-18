const std = @import("std");
const Io = std.Io;
const url = @import("url.zig");
const git = @import("git.zig");

const DirEntry = struct {
    name: []const u8,
    kind: Io.File.Kind,
    is_symlink: bool,
    /// For symlinks: the resolved target kind. null means broken symlink.
    target_kind: ?Io.File.Kind,
    size: u64,

    /// Effective kind for sorting: use target_kind for symlinks, kind otherwise.
    fn effectiveKind(self: DirEntry) Io.File.Kind {
        if (self.is_symlink) {
            return self.target_kind orelse .unknown;
        }
        return self.kind;
    }

    fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
        const ak = a.effectiveKind();
        const bk = b.effectiveKind();
        if (ak == .directory and bk != .directory) return true;
        if (ak != .directory and bk == .directory) return false;
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
    enable_terminal: bool,
) !void {
    var dir = try root_dir.openDir(io, dir_path, .{
        .iterate = true,
        .follow_symlinks = true,
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
        const is_symlink = entry.kind == .sym_link;

        // Build the full path for this entry (needed for open calls)
        const full_path = if (dir_path.len == 0 or std.mem.eql(u8, dir_path, "."))
            entry.name
        else
            try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer if (dir_path.len > 0 and !std.mem.eql(u8, dir_path, ".")) allocator.free(full_path);

        var target_kind: ?Io.File.Kind = null;
        var size: u64 = 0;

        if (is_symlink) {
            // Try to resolve the symlink target by opening as a file first,
            // then as a directory. openFile/openDir follow symlinks by default.
            if (root_dir.openFile(io, full_path, .{})) |file| {
                file.close(io);
                target_kind = .file;
                // Get file size through the symlink
                if (root_dir.openFile(io, full_path, .{})) |f| {
                    defer f.close(io);
                    size = f.length(io) catch 0;
                } else |_| {}
            } else |_| {
                // Not a file — try as directory
                if (root_dir.openDir(io, full_path, .{ .iterate = false, .follow_symlinks = true })) |d| {
                    d.close(io);
                    target_kind = .directory;
                } else |_| {
                    // Broken symlink — target_kind stays null
                }
            }
        } else if (entry.kind == .file) {
            const file = root_dir.openFile(io, full_path, .{}) catch null;
            if (file) |f| {
                defer f.close(io);
                size = f.length(io) catch 0;
            }
        }

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .kind = entry.kind,
            .is_symlink = is_symlink,
            .target_kind = target_kind,
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
        \\  <meta name="color-scheme" content="light dark">
        \\  <style>
        \\    :root {
        \\      --bg-color: #ffffff;
        \\      --text-color: #24292e;
        \\      --text-secondary: #666;
        \\      --border-color: #e2e8f0;
        \\      --link-color: #0366d6;
        \\      --hover-bg: #e5e7eb;
        \\      --upload-form-bg-start: #f8fafc;
        \\      --upload-form-bg-end: #f1f5f9;
        \\      --file-input-bg: #fff;
        \\      --file-input-border: #cbd5e1;
        \\      --file-input-color: #64748b;
        \\      --file-input-hover-border: #3b82f6;
        \\      --file-input-hover-bg: #eff6ff;
        \\      --filename-color: #334155;
        \\      --bulk-actions-bg: #f8fafc;
        \\      --delete-btn-bg: #fee2e2;
        \\      --delete-btn-border: #fecaca;
        \\      --delete-btn-color: #dc2626;
        \\      --delete-btn-hover-bg: #fecaca;
        \\      --tail-btn-bg: #dbeafe;
        \\      --tail-btn-border: #bfdbfe;
        \\      --tail-btn-color: #2563eb;
        \\      --tail-btn-hover-bg: #bfdbfe;
        \\      --exec-btn-bg: #dcfce7;
        \\      --exec-btn-border: #bbf7d0;
        \\      --exec-btn-color: #16a34a;
        \\      --exec-btn-hover-bg: #bbf7d0;
        \\      --truncate-btn-bg: #fef3c7;
        \\      --truncate-btn-border: #fde68a;
        \\      --truncate-btn-color: #d97706;
        \\      --truncate-btn-hover-bg: #fde68a;
        \\      --download-btn-bg: #ede9fe;
        \\      --download-btn-border: #ddd6fe;
        \\      --download-btn-color: #7c3aed;
        \\      --download-btn-hover-bg: #ddd6fe;
        \\      --theme-toggle-bg: #f1f5f9;
        \\      --theme-toggle-color: #475569;
        \\      --theme-toggle-border: #e2e8f0;
        \\    }
        \\    @media (prefers-color-scheme: dark) {
        \\      :root {
        \\        --bg-color: #0d1117;
        \\        --text-color: #c9d1d9;
        \\        --text-secondary: #8b949e;
        \\        --border-color: #30363d;
        \\        --link-color: #58a6ff;
        \\        --hover-bg: #21262d;
        \\        --upload-form-bg-start: #161b22;
        \\        --upload-form-bg-end: #0d1117;
        \\        --file-input-bg: #21262d;
        \\        --file-input-border: #30363d;
        \\        --file-input-color: #8b949e;
        \\        --file-input-hover-border: #58a6ff;
        \\        --file-input-hover-bg: #1f2937;
        \\        --filename-color: #c9d1d9;
        \\        --bulk-actions-bg: #161b22;
        \\        --delete-btn-bg: #3d1f1f;
        \\        --delete-btn-border: #5c2b2b;
        \\        --delete-btn-color: #f85149;
        \\        --delete-btn-hover-bg: #5c2b2b;
        \\        --tail-btn-bg: #1f2937;
        \\        --tail-btn-border: #374151;
        \\        --tail-btn-color: #58a6ff;
        \\        --tail-btn-hover-bg: #374151;
        \\        --exec-btn-bg: #1c3d23;
        \\        --exec-btn-border: #2d5a35;
        \\        --exec-btn-color: #3fb950;
        \\        --exec-btn-hover-bg: #2d5a35;
        \\        --truncate-btn-bg: #451a03;
        \\        --truncate-btn-border: #78350f;
        \\        --truncate-btn-color: #fbbf24;
        \\        --truncate-btn-hover-bg: #78350f;
        \\        --download-btn-bg: #2e1065;
        \\        --download-btn-border: #5b21b6;
        \\        --download-btn-color: #a78bfa;
        \\        --download-btn-hover-bg: #5b21b6;
        \\        --theme-toggle-bg: #21262d;
        \\        --theme-toggle-color: #c9d1d9;
        \\        --theme-toggle-border: #30363d;
        \\      }
        \\    }
        \\    body.dark-mode {
        \\      --bg-color: #0d1117;
        \\      --text-color: #c9d1d9;
        \\      --text-secondary: #8b949e;
        \\      --border-color: #30363d;
        \\      --link-color: #58a6ff;
        \\      --hover-bg: #21262d;
        \\      --upload-form-bg-start: #161b22;
        \\      --upload-form-bg-end: #0d1117;
        \\      --file-input-bg: #21262d;
        \\      --file-input-border: #30363d;
        \\      --file-input-color: #8b949e;
        \\      --file-input-hover-border: #58a6ff;
        \\      --file-input-hover-bg: #1f2937;
        \\      --filename-color: #c9d1d9;
        \\      --bulk-actions-bg: #161b22;
        \\      --delete-btn-bg: #3d1f1f;
        \\      --delete-btn-border: #5c2b2b;
        \\      --delete-btn-color: #f85149;
        \\      --delete-btn-hover-bg: #5c2b2b;
        \\      --tail-btn-bg: #1f2937;
        \\      --tail-btn-border: #374151;
        \\      --tail-btn-color: #58a6ff;
        \\      --tail-btn-hover-bg: #374151;
        \\      --exec-btn-bg: #1c3d23;
        \\      --exec-btn-border: #2d5a35;
        \\      --exec-btn-color: #3fb950;
        \\      --exec-btn-hover-bg: #2d5a35;
        \\      --theme-toggle-bg: #21262d;
        \\      --theme-toggle-color: #c9d1d9;
        \\      --theme-toggle-border: #30363d;
        \\    }
        \\    body { font-family: sans-serif; margin: 2em; background-color: var(--bg-color); color: var(--text-color); transition: background-color 0.3s, color 0.3s; }
        \\    .directory { font-weight: bold; color: var(--link-color); }
        \\    .file { color: var(--text-color); }
        \\    ul { list-style-type: none; padding: 0; }
        \\    li { margin: 0.5em 0; display: flex; align-items: center; padding: 0.4em 0.8em; border-radius: 8px; transition: background-color 0.2s; }
        \\    li:hover { background-color: var(--hover-bg); }
        \\    li a { flex: 1; text-decoration: none; }
        \\    .size { color: var(--text-secondary); margin-left: 1em; min-width: 6em; text-align: right; }
        \\    a:hover { text-decoration: underline; }
        \\    .upload-form { margin: 1.5em 0; padding: 1.5em; background: linear-gradient(135deg, var(--upload-form-bg-start) 0%, var(--upload-form-bg-end) 100%); border-radius: 12px; border: 1px solid var(--border-color); box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        \\    .upload-form form { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
        \\    .file-input-wrapper { position: relative; display: inline-block; }
        \\    .file-input-wrapper input[type="file"] { position: absolute; opacity: 0; width: 100%; height: 100%; cursor: pointer; }
        \\    .file-input-label { display: inline-flex; align-items: center; gap: 8px; padding: 10px 18px; background: var(--file-input-bg); border: 2px dashed var(--file-input-border); border-radius: 8px; color: var(--file-input-color); font-size: 14px; cursor: pointer; transition: all 0.2s; }
        \\    .file-input-wrapper:hover .file-input-label { border-color: var(--file-input-hover-border); color: var(--file-input-hover-border); background: var(--file-input-hover-bg); }
        \\    .file-input-label::before { content: "📎"; font-size: 16px; }
        \\    .upload-btn { display: inline-flex; align-items: center; gap: 8px; padding: 10px 20px; background: linear-gradient(135deg, #3b82f6 0%, #2563eb 100%); color: white; border: none; border-radius: 8px; font-size: 14px; font-weight: 500; cursor: pointer; transition: all 0.2s; box-shadow: 0 2px 4px rgba(37, 99, 235, 0.3); }
        \\    .upload-btn:hover { transform: translateY(-1px); box-shadow: 0 4px 8px rgba(37, 99, 235, 0.4); }
        \\    .upload-btn:active { transform: translateY(0); }
        \\    .upload-btn::before { content: "⬆️"; font-size: 14px; }
        \\    .file-name { color: var(--filename-color); font-size: 14px; margin-left: 8px; }
        \\    .delete-btn { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: var(--delete-btn-bg); border: 1px solid var(--delete-btn-border); border-radius: 6px; color: var(--delete-btn-color); font-size: 14px; cursor: pointer; transition: all 0.2s; margin-left: 8px; }
        \\    .delete-btn:hover { background: var(--delete-btn-hover-bg); transform: scale(1.05); }
        \\    .delete-btn:active { transform: scale(0.95); }
        \\    .tail-btn { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: var(--tail-btn-bg); border: 1px solid var(--tail-btn-border); border-radius: 6px; color: var(--tail-btn-color); font-size: 14px; cursor: pointer; transition: all 0.2s; margin-left: 8px; }
        \\    .tail-btn:hover { background: var(--tail-btn-hover-bg); transform: scale(1.05); }
        \\    .tail-btn:active { transform: scale(0.95); }
        \\    .exec-btn { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: var(--exec-btn-bg); border: 1px solid var(--exec-btn-border); border-radius: 6px; color: var(--exec-btn-color); font-size: 14px; cursor: pointer; transition: all 0.2s; margin-left: 8px; }
        \\    .exec-btn:hover { background: var(--exec-btn-hover-bg); transform: scale(1.05); }
        \\    .exec-btn:active { transform: scale(0.95); }
        \\    .truncate-btn { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: var(--truncate-btn-bg); border: 1px solid var(--truncate-btn-border); border-radius: 6px; color: var(--truncate-btn-color); font-size: 14px; cursor: pointer; transition: all 0.2s; margin-left: 8px; }
        \\    .truncate-btn:hover { background: var(--truncate-btn-hover-bg); transform: scale(1.05); }
        \\    .truncate-btn:active { transform: scale(0.95); }
        \\    .download-btn { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; background: var(--download-btn-bg); border: 1px solid var(--download-btn-border); border-radius: 6px; color: var(--download-btn-color); font-size: 14px; cursor: pointer; transition: all 0.2s; margin-left: 8px; }
        \\    .download-btn:hover { background: var(--download-btn-hover-bg); transform: scale(1.05); }
        \\    .download-btn:active { transform: scale(0.95); }
        \\    .bulk-actions { display: flex; align-items: center; gap: 12px; margin: 1em 0; padding: 0.8em 1em; background: var(--bulk-actions-bg); border-radius: 8px; border: 1px solid var(--border-color); }
        \\    .bulk-actions input[type="checkbox"] { width: 18px; height: 18px; cursor: pointer; accent-color: #3b82f6; }
        \\    .bulk-actions label { cursor: pointer; font-size: 14px; color: var(--filename-color); user-select: none; }
        \\    .delete-selected-btn { display: inline-flex; align-items: center; gap: 6px; padding: 8px 16px; background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%); color: white; border: none; border-radius: 6px; font-size: 14px; font-weight: 500; cursor: pointer; transition: all 0.2s; }
        \\    .delete-selected-btn:hover:not(:disabled) { transform: translateY(-1px); box-shadow: 0 4px 8px rgba(220, 38, 38, 0.3); }
        \\    .delete-selected-btn:disabled { background: #cbd5e1; cursor: not-allowed; opacity: 0.6; }
        \\    .item-checkbox { width: 18px; height: 18px; cursor: pointer; accent-color: #3b82f6; margin-right: 12px; flex-shrink: 0; }
        \\    .theme-toggle { position: fixed; top: 20px; right: 20px; display: inline-flex; align-items: center; gap: 6px; padding: 8px 12px; background: var(--theme-toggle-bg); border: 1px solid var(--theme-toggle-border); border-radius: 6px; color: var(--theme-toggle-color); font-size: 14px; cursor: pointer; transition: all 0.2s; z-index: 2000; }
        \\    .theme-toggle:hover { transform: scale(1.05); }
        \\    .theme-toggle:active { transform: scale(0.95); }
        \\    .git-toggle { position: fixed; top: 20px; right: 90px; display: inline-flex; align-items: center; gap: 6px; padding: 8px 12px; background: var(--exec-btn-bg); border: 1px solid var(--exec-btn-border); border-radius: 6px; color: var(--exec-btn-color); font-size: 14px; cursor: pointer; transition: all 0.2s; z-index: 2000; }
        \\    .git-toggle:hover { transform: scale(1.05); }
        \\    .git-toggle:active { transform: scale(0.95); }
        \\    .terminal-toggle { position: fixed; top: 20px; right: 160px; display: inline-flex; align-items: center; gap: 6px; padding: 8px 12px; background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%); border: 1px solid #334155; border-radius: 6px; color: #38bdf8; font-size: 14px; cursor: pointer; transition: all 0.2s; z-index: 2000; text-decoration: none; }
        \\    .terminal-toggle:hover { transform: scale(1.05); box-shadow: 0 0 12px rgba(56, 189, 248, 0.4); }
        \\    .terminal-toggle:active { transform: scale(0.95); }
        \\    .toast-container { position: fixed; top: 20px; right: 20px; z-index: 1000; display: flex; flex-direction: column; gap: 10px; }
        \\    .toast { padding: 16px 20px; border-radius: 8px; box-shadow: 0 4px 12px rgba(0,0,0,0.15); display: flex; align-items: center; gap: 12px; min-width: 300px; max-width: 450px; animation: slideIn 0.3s ease; transition: all 0.3s ease; }
        \\    .toast.success { background: linear-gradient(135deg, #10b981 0%, #059669 100%); color: white; }
        \\    .toast.error { background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%); color: white; }
        \\    .toast.warning { background: linear-gradient(135deg, #f59e0b 0%, #d97706 100%); color: white; }
        \\    .toast-icon { font-size: 20px; }
        \\    .toast-content { flex: 1; }
        \\    .toast-title { font-weight: 600; font-size: 14px; margin-bottom: 2px; }
        \\    .toast-message { font-size: 13px; opacity: 0.95; }
        \\    .toast-close { background: none; border: none; color: inherit; font-size: 18px; cursor: pointer; padding: 0; width: 24px; height: 24px; display: flex; align-items: center; justify-content: center; opacity: 0.8; transition: opacity 0.2s; }
        \\    .toast-close:hover { opacity: 1; }
        \\    .toast-progress { position: absolute; bottom: 0; left: 0; height: 3px; background: rgba(255,255,255,0.5); border-radius: 0 0 0 8px; transition: width 0.1s linear; }
        \\    @keyframes slideIn { from { transform: translateX(100%); opacity: 0; } to { transform: translateX(0); opacity: 1; } }
        \\    @keyframes slideOut { from { transform: translateX(0); opacity: 1; } to { transform: translateX(100%); opacity: 0; } }
        \\    .toast.hiding { animation: slideOut 0.3s ease forwards; }
        \\    .deleting-overlay { position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.3); display: flex; align-items: center; justify-content: center; z-index: 999; opacity: 0; pointer-events: none; transition: opacity 0.3s; }
        \\    .deleting-overlay.show { opacity: 1; pointer-events: all; }
        \\    .deleting-spinner { background: var(--bg-color); padding: 24px 32px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.2); display: flex; flex-direction: column; align-items: center; gap: 12px; color: var(--text-color); }
        \\    .spinner { width: 40px; height: 40px; border: 3px solid #e5e7eb; border-top-color: #3b82f6; border-radius: 50%; animation: spin 1s linear infinite; }
        \\    @keyframes spin { to { transform: rotate(360deg); } }
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
        \\      window.open('/execute?file=' + encodeURIComponent(path), '_blank');
        \\    }
        \\    function confirmTruncate(filename, encodedPath) {
        \\      if (!confirm('Are you sure you want to truncate "' + filename + '"?\n\nWARNING: This will permanently delete ALL content in the file!\n\nThis action cannot be undone!')) {
        \\        return;
        \\      }
        \\      fetch('/truncate?file=' + encodedPath, { method: 'POST' })
        \\        .then(response => {
        \\          if (response.ok) {
        \\            window.location.reload();
        \\          } else {
        \\            alert('Failed to truncate file');
        \\          }
        \\        })
        \\        .catch(err => {
        \\          alert('Error: ' + err.message);
        \\        });
        \\    }
        \\    // Theme toggle functionality
        \\    function initTheme() {
        \\      const savedTheme = localStorage.getItem('theme');
        \\      if (savedTheme === 'dark') {
        \\        document.body.classList.add('dark-mode');
        \\      } else if (savedTheme === 'light') {
        \\        document.body.classList.remove('dark-mode');
        \\      } else {
        \\        // Use system preference
        \\        if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
        \\          document.body.classList.add('dark-mode');
        \\        }
        \\      }
        \\      updateThemeToggle();
        \\    }
        \\    function toggleTheme() {
        \\      const isDark = document.body.classList.toggle('dark-mode');
        \\      localStorage.setItem('theme', isDark ? 'dark' : 'light');
        \\      updateThemeToggle();
        \\    }
        \\    function updateThemeToggle() {
        \\      const btn = document.getElementById('themeToggle');
        \\      if (btn) {
        \\        const isDark = document.body.classList.contains('dark-mode');
        \\        btn.textContent = isDark ? '☀️ Light' : '🌙 Dark';
        \\      }
        \\    }
        \\    // Bulk delete functionality
        \\    function toggleSelectAll() {
        \\      const selectAllCheckbox = document.getElementById('selectAll');
        \\      const checkboxes = document.querySelectorAll('.item-checkbox');
        \\      checkboxes.forEach(cb => cb.checked = selectAllCheckbox.checked);
        \\      updateDeleteSelectedButton();
        \\    }
        \\    function updateDeleteSelectedButton() {
        \\      const checkedBoxes = document.querySelectorAll('.item-checkbox:checked');
        \\      const btn = document.getElementById('deleteSelectedBtn');
        \\      btn.textContent = checkedBoxes.length > 0 ? 'Delete Selected (' + checkedBoxes.length + ')' : 'Delete Selected';
        \\      btn.disabled = checkedBoxes.length === 0;
        \\    }
        \\    function showToast(type, title, message, duration = 5000) {
        \\      let container = document.getElementById('toastContainer');
        \\      if (!container) {
        \\        container = document.createElement('div');
        \\        container.id = 'toastContainer';
        \\        container.className = 'toast-container';
        \\        document.body.appendChild(container);
        \\      }
        \\      const toast = document.createElement('div');
        \\      toast.className = 'toast ' + type;
        \\      const icon = type === 'success' ? '✓' : type === 'error' ? '✕' : '⚠';
        \\      toast.innerHTML = '<span class="toast-icon">' + icon + '</span><div class="toast-content"><div class="toast-title">' + title + '</div><div class="toast-message">' + message + '</div></div><button class="toast-close" onclick="this.parentElement.remove()">×</button><div class="toast-progress"></div>';
        \\      container.appendChild(toast);
        \\      const progressBar = toast.querySelector('.toast-progress');
        \\      if (duration > 0) {
        \\        let remaining = duration;
        \\        const interval = 50;
        \\        const timer = setInterval(() => {
        \\          remaining -= interval;
        \\          const pct = (remaining / duration) * 100;
        \\          progressBar.style.width = pct + '%';
        \\          if (remaining <= 0) {
        \\            clearInterval(timer);
        \\            hideToast(toast);
        \\          }
        \\        }, interval);
        \\        toast.dataset.timer = timer;
        \\      }
        \\      return toast;
        \\    }
        \\    function hideToast(toast) {
        \\      toast.classList.add('hiding');
        \\      setTimeout(() => toast.remove(), 300);
        \\    }
        \\    function showDeletingOverlay(message) {
        \\      let overlay = document.getElementById('deletingOverlay');
        \\      if (!overlay) {
        \\        overlay = document.createElement('div');
        \\        overlay.id = 'deletingOverlay';
        \\        overlay.className = 'deleting-overlay';
        \\        overlay.innerHTML = '<div class="deleting-spinner"><div class="spinner"></div><span id="deletingMessage">Deleting...</span></div>';
        \\        document.body.appendChild(overlay);
        \\      }
        \\      document.getElementById('deletingMessage').textContent = message;
        \\      overlay.classList.add('show');
        \\    }
        \\    function hideDeletingOverlay() {
        \\      const overlay = document.getElementById('deletingOverlay');
        \\      if (overlay) overlay.classList.remove('show');
        \\    }
        \\    async function deleteSelected() {
        \\      const checkboxes = document.querySelectorAll('.item-checkbox:checked');
        \\      if (checkboxes.length === 0) return;
        \\      const items = Array.from(checkboxes).map(cb => ({
        \\        name: cb.dataset.name,
        \\        path: cb.dataset.path,
        \\        isDirectory: cb.dataset.isDirectory === 'true'
        \\      }));
        \\      const dirCount = items.filter(i => i.isDirectory).length;
        \\      const fileCount = items.length - dirCount;
        \\      let confirmMsg = 'Are you sure you want to delete:\n';
        \\      if (fileCount > 0) confirmMsg += '- ' + fileCount + ' file(s)\n';
        \\      if (dirCount > 0) confirmMsg += '- ' + dirCount + ' director' + (dirCount === 1 ? 'y' : 'ies') + ' (and ALL their contents)\n';
        \\      confirmMsg += '\nThis action cannot be undone!';
        \\      if (!confirm(confirmMsg)) return;
        \\      const btn = document.getElementById('deleteSelectedBtn');
        \\      btn.disabled = true;
        \\      showDeletingOverlay('Deleting ' + items.length + ' item(s)...');
        \\      let successCount = 0;
        \\      let failCount = 0;
        \\      const failedItems = [];
        \\      for (let i = 0; i < items.length; i++) {
        \\        const item = items[i];
        \\        document.getElementById('deletingMessage').textContent = 'Deleting ' + (i + 1) + ' of ' + items.length + ': ' + item.name;
        \\        try {
        \\          const response = await fetch('/' + item.path, { method: 'DELETE' });
        \\          if (response.ok) {
        \\            successCount++;
        \\          } else {
        \\            failCount++;
        \\            failedItems.push(item.name);
        \\            console.error('Failed to delete:', item.path);
        \\          }
        \\        } catch (err) {
        \\          failCount++;
        \\          failedItems.push(item.name);
        \\          console.error('Error deleting:', item.path, err);
        \\        }
        \\      }
        \\      hideDeletingOverlay();
        \\      if (failCount === 0) {
        \\        showToast('success', 'Deletion Complete', 'Successfully deleted ' + successCount + ' item(s).', 3000);
        \\        setTimeout(() => window.location.reload(), 1500);
        \\      } else if (successCount === 0) {
        \\        showToast('error', 'Deletion Failed', 'Failed to delete all ' + failCount + ' item(s).', 0);
        \\        btn.disabled = false;
        \\      } else {
        \\        showToast('warning', 'Partially Complete', 'Deleted ' + successCount + ' item(s), failed to delete ' + failCount + ' item(s): ' + failedItems.slice(0, 3).join(', ') + (failedItems.length > 3 ? '...' : ''), 0);
        \\        setTimeout(() => window.location.reload(), 3000);
        \\      }
        \\    }
        \\  </script>
        \\</head><body onload="initTheme()">
        \\  <button id="themeToggle" class="theme-toggle" onclick="toggleTheme()">🌙 Dark</button>
        \\  <h1>Directory listing:
    );

    const title = if (dir_path.len == 0) "/" else dir_path;
    try stream_writer.interface.writeAll(title);
    // Conditionally show git button — walk up parent dirs to find a git repo
    if (git.findGitRoot(io, allocator, dir)) |git_root| {
        defer if (git_root.levels_up > 0) git_root.dir.close(io);
        defer allocator.free(git_root.abs_path);

        // Determine if the git root is within root_dir or above it
        const root_real = git.getDirRealPath(io, allocator, root_dir) catch git_root.abs_path;
        defer if (root_real.ptr != git_root.abs_path.ptr) allocator.free(root_real);

        const git_is_above_root = git_root.abs_path.len < root_real.len and
            std.mem.startsWith(u8, root_real, git_root.abs_path);

        if (git_is_above_root) {
            // Git root is above root_dir — pass absolute path
            const encoded_abs = url.encode(allocator, git_root.abs_path) catch git_root.abs_path;
            defer if (encoded_abs.ptr != git_root.abs_path.ptr) allocator.free(encoded_abs);
            try stream_writer.interface.writeAll("  <button id=\"gitToggle\" class=\"git-toggle\" onclick=\"window.location.href='/__git__?git_root_abs=");
            try stream_writer.interface.writeAll(encoded_abs);
            try stream_writer.interface.writeAll("'\">🌿 Git</button>\n");
        } else {
            // Git root is within root_dir — use the existing path= parameter
            const encoded_git_path = url.encode(allocator, dir_path) catch dir_path;
            defer if (encoded_git_path.ptr != dir_path.ptr) allocator.free(encoded_git_path);
            try stream_writer.interface.writeAll("  <button id=\"gitToggle\" class=\"git-toggle\" onclick=\"window.location.href='/__git__?path=");
            try stream_writer.interface.writeAll(encoded_git_path);
            try stream_writer.interface.writeAll("'\">🌿 Git</button>\n");
        }
    }

    // Add terminal button if terminal is enabled
    if (enable_terminal) {
        // Include the current directory path so the terminal opens in the right CWD
        if (std.mem.eql(u8, dir_path, ".") or dir_path.len == 0) {
            try stream_writer.interface.writeAll("  <a href=\"/__terminal__\" class=\"terminal-toggle\">🖥️ Terminal</a>\n");
        } else {
            const encoded_path = try url.encode(allocator, dir_path);
            try stream_writer.interface.writeAll("  <a href=\"/__terminal__?path=");
            try stream_writer.interface.writeAll(encoded_path);
            try stream_writer.interface.writeAll("\" class=\"terminal-toggle\">🖥️ Terminal</a>\n");
        }
    }

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
        \\  <div class="bulk-actions">
        \\    <input type="checkbox" id="selectAll" onchange="toggleSelectAll()">
        \\    <label for="selectAll">Select All</label>
        \\    <button id="deleteSelectedBtn" class="delete-selected-btn" onclick="deleteSelected()" disabled>Delete Selected</button>
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
    const effective_kind = entry.effectiveKind();
    const class = if (effective_kind == .directory) "directory" else "file";
    const encoded_name = try url.encode(allocator, entry.name);
    defer allocator.free(encoded_name);

    // Build full path for checkbox data attribute
    const full_path = if (std.mem.eql(u8, dir_path, "."))
        entry.name
    else
        try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
    defer if (!std.mem.eql(u8, dir_path, ".")) allocator.free(full_path);
    const is_dir = effective_kind == .directory;

    // Add checkbox for bulk selection
    try writer.writeAll("<li><input type=\"checkbox\" class=\"item-checkbox\" onchange=\"updateDeleteSelectedButton()\" data-name=\"");
    // Escape HTML special chars in name for data attribute
    for (entry.name) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("\" data-path=\"");
    // Escape HTML special chars in path for data attribute
    for (full_path) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll(if (is_dir) "\" data-is-directory=\"true\">" else "\" data-is-directory=\"false\">");

    try writer.writeAll("<a href=\"/");

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

    if (effective_kind == .directory) {
        try writer.writeAll("/");
    }
    // Symlink indicator
    if (entry.is_symlink) {
        if (entry.target_kind) |tk| {
            if (tk == .directory) {
                try writer.writeAll(" <span title=\"Symlink to directory\" style=\"font-size:0.85em;opacity:0.8;\">🔗→📁</span>");
            } else {
                try writer.writeAll(" <span title=\"Symlink to file\" style=\"font-size:0.85em;opacity:0.8;\">🔗→📄</span>");
            }
        } else {
            try writer.writeAll(" <span title=\"Broken symlink\" style=\"font-size:0.85em;color:#ef4444;\">🔗⚠️</span>");
        }
    }

    try writer.writeAll("</a><span class=\"size\">");

    // Format size
    if (entry.kind == .directory) {
        try writer.writeAll("-");
    } else {
        try formatSize(writer, entry.size);
    }

    try writer.writeAll("</span>");

    // Add truncate button for log files (before delete button)
    if (!is_dir and entry.target_kind != null and isLogFile(entry.name)) {
        try writer.writeAll("<button class=\"truncate-btn\" onclick=\"confirmTruncate('");
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
        // URL encode the path for the truncate endpoint
        const url_encoded_path = try url.encode(allocator, full_path);
        defer allocator.free(url_encoded_path);
        // Escape single quotes in encoded path for JS
        for (url_encoded_path) |c| {
            switch (c) {
                '\\', '\'' => {
                    try writer.writeByte('\\');
                    try writer.writeByte(c);
                },
                else => try writer.writeByte(c),
            }
        }
        try writer.writeAll("')\" title=\"Truncate log file\">✂️</button>");
    }

    // Add delete button for all entries (files and directories)
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
    if (is_dir) {
        try writer.writeAll("', true)\" title=\"Delete directory\">🗑️</button>");
    } else {
        try writer.writeAll("', false)\" title=\"Delete file\">🗑️</button>");

        // Add Download button for files (skip broken symlinks)
        if (entry.is_symlink and entry.target_kind == null) {
            try writer.writeAll("</li>\n");
            return;
        }

        // Add Download button for files
        try writer.writeAll("<button class=\"download-btn\" onclick=\"window.location.href='/download?file=");
        // Escape the path for URL
        const url_encoded_path = try url.encode(allocator, full_path);
        defer allocator.free(url_encoded_path);
        try writer.writeAll(url_encoded_path);
        try writer.writeAll("'\" title=\"Download file\">⬇️</button>");

        // Add Tail button for text files
        if (!is_dir and isTextFile(entry.name)) {
            try writer.writeAll("<button class=\"tail-btn\" onclick=\"window.open('/tail?file=");
            // Escape the path for URL - reuse the same encoded path
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

/// Check if a file is a log file based on extension
fn isLogFile(filename: []const u8) bool {
    const log_extensions = &[_][]const u8{
        ".log", ".txt", ".out", ".err",
    };

    // Convert filename to lowercase for case-insensitive comparison
    var lower_buf: [256]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buf, filename);

    for (log_extensions) |ext| {
        if (std.mem.endsWith(u8, lower, ext)) {
            return true;
        }
    }

    // Special case for files commonly used as log files
    const log_names = &[_][]const u8{
        "log", "logs", "access_log", "error_log", "debug_log", "stdout", "stderr",
    };

    for (log_names) |name| {
        if (std.mem.eql(u8, lower, name)) {
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
