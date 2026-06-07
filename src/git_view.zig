const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const git = @import("git.zig");

/// Escape HTML special characters into an ArrayList
fn appendEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '&' => try list.appendSlice(allocator, "&amp;"),
            '<' => try list.appendSlice(allocator, "&lt;"),
            '>' => try list.appendSlice(allocator, "&gt;"),
            '"' => try list.appendSlice(allocator, "&quot;"),
            '\'' => try list.appendSlice(allocator, "&#x27;"),
            else => try list.append(allocator, c),
        }
    }
}

fn statusBadge(status: git.FileStatus) struct { label: []const u8, class: []const u8 } {
    return switch (status) {
        .modified => .{ .label = "M", .class = "badge-modified" },
        .staged_modified => .{ .label = "M", .class = "badge-staged" },
        .added => .{ .label = "A", .class = "badge-added" },
        .staged_added => .{ .label = "A", .class = "badge-staged" },
        .deleted => .{ .label = "D", .class = "badge-deleted" },
        .staged_deleted => .{ .label = "D", .class = "badge-staged-del" },
        .renamed => .{ .label = "R", .class = "badge-renamed" },
        .untracked => .{ .label = "?", .class = "badge-untracked" },
    };
}

/// Serve the full git view HTML page.
/// `git_dir` is the resolved git root directory (already opened by caller).
/// `dir_path` is used for the back-link URL only.
/// `git_root_abs` is the absolute path when the git root is above root_dir (for JS AJAX calls).
pub fn serveGitView(io: Io, allocator: std.mem.Allocator, stream: Io.net.Stream, git_dir: Io.Dir, dir_path: []const u8, git_root_abs: ?[]const u8) !void {
    const is_root = dir_path.len == 0 or std.mem.eql(u8, dir_path, ".");

    var status = git.getGitStatus(io, allocator, git_dir) catch |err| {
        std.debug.print("Failed to get git status: {s}\n", .{@errorName(err)});
        try http.sendErrorResponse(stream, io, .internal_server_error, "Failed to get git status");
        return;
    };
    defer status.deinit();

    const log_text = git.getGitLog(io, allocator, git_dir) catch try allocator.dupe(u8, "(no log available)");
    defer allocator.free(log_text);

    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/html; charset=utf-8" },
    });

    var write_buf: [65536]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    const w = &stream_writer.interface;

    // Build HTML using a mix of static writeAll and dynamic ArrayList
    var html = std.ArrayList(u8).initCapacity(allocator, 65536) catch return error.OutOfMemory;
    defer html.deinit(allocator);

    try html.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html><head>
        \\  <meta charset="utf-8">
        \\  <meta name="viewport" content="width=device-width, initial-scale=1">
        \\  <meta name="color-scheme" content="light dark">
        \\  <title>Git Status</title>
        \\  <style>
        \\    :root {
        \\      --bg: #ffffff; --bg2: #f6f8fa; --bg3: #f1f5f9;
        \\      --text: #24292e; --text2: #57606a; --border: #d0d7de;
        \\      --link: #0969da; --hover: #eaeef2;
        \\      --add-bg: #e6ffec; --add-text: #1a7f37;
        \\      --del-bg: #ffebe9; --del-text: #cf222e;
        \\      --hunk-bg: #ddf4ff; --hunk-text: #0550ae;
        \\      --meta-bg: #f6f8fa; --meta-text: #57606a;
        \\      --panel-bg: #ffffff; --panel-border: #d0d7de;
        \\    }
        \\    @media (prefers-color-scheme: dark) {
        \\      :root {
        \\        --bg: #0d1117; --bg2: #161b22; --bg3: #21262d;
        \\        --text: #c9d1d9; --text2: #8b949e; --border: #30363d;
        \\        --link: #58a6ff; --hover: #21262d;
        \\        --add-bg: #0d2b1a; --add-text: #3fb950;
        \\        --del-bg: #2d0f0f; --del-text: #f85149;
        \\        --hunk-bg: #0c2d4a; --hunk-text: #79c0ff;
        \\        --meta-bg: #161b22; --meta-text: #8b949e;
        \\        --panel-bg: #161b22; --panel-border: #30363d;
        \\      }
        \\    }
        \\    body.dark-mode {
        \\      --bg: #0d1117; --bg2: #161b22; --bg3: #21262d;
        \\      --text: #c9d1d9; --text2: #8b949e; --border: #30363d;
        \\      --link: #58a6ff; --hover: #21262d;
        \\      --add-bg: #0d2b1a; --add-text: #3fb950;
        \\      --del-bg: #2d0f0f; --del-text: #f85149;
        \\      --hunk-bg: #0c2d4a; --hunk-text: #79c0ff;
        \\      --meta-bg: #161b22; --meta-text: #8b949e;
        \\      --panel-bg: #161b22; --panel-border: #30363d;
        \\    }
        \\    * { box-sizing: border-box; }
        \\    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; background: var(--bg); color: var(--text); }
        \\    .header { background: linear-gradient(135deg, #2d6a4f 0%, #1b4332 100%); color: white; padding: 0.8em 1.5em; display: flex; align-items: center; justify-content: space-between; box-shadow: 0 2px 8px rgba(0,0,0,0.2); }
        \\    .header h1 { margin: 0; font-size: 1.1em; font-weight: 600; display: flex; align-items: center; gap: 8px; }
        \\    .header-right { display: flex; align-items: center; gap: 10px; }
        \\    .branch-badge { background: rgba(255,255,255,0.2); padding: 4px 10px; border-radius: 20px; font-size: 13px; font-family: monospace; }
        \\    .back-btn { color: white; text-decoration: none; padding: 6px 14px; background: rgba(255,255,255,0.15); border-radius: 6px; font-size: 13px; transition: background 0.2s; }
        \\    .back-btn:hover { background: rgba(255,255,255,0.25); }
        \\    .theme-toggle { padding: 6px 12px; background: rgba(255,255,255,0.15); border: none; border-radius: 6px; color: white; font-size: 13px; cursor: pointer; transition: background 0.2s; }
        \\    .theme-toggle:hover { background: rgba(255,255,255,0.25); }
        \\    .layout { display: flex; height: calc(100vh - 52px); overflow: hidden; }
        \\    .sidebar { width: 320px; min-width: 220px; max-width: 480px; border-right: 1px solid var(--border); display: flex; flex-direction: column; background: var(--bg2); overflow: hidden; }
        \\    .sidebar-header { padding: 0.75em 1em; border-bottom: 1px solid var(--border); font-weight: 600; font-size: 13px; color: var(--text2); text-transform: uppercase; letter-spacing: 0.05em; background: var(--bg3); cursor: pointer; display: flex; justify-content: space-between; align-items: center; transition: background 0.15s; }
        \\    .sidebar-header:hover { background: var(--hover); }
        \\    .file-list { flex: 1; overflow-y: auto; }
        \\    .file-list-container { display: block; overflow-y: auto; max-height: none; }
        \\    .file-list-container.collapsed { display: none; }
        \\    .file-item { display: flex; align-items: center; gap: 8px; padding: 8px 12px; cursor: pointer; border-bottom: 1px solid var(--border); transition: background 0.15s; font-size: 13px; }
        \\    .file-item:hover { background: var(--hover); }
        \\    .file-item.active { background: var(--hover); border-left: 3px solid #2d6a4f; padding-left: 9px; }
        \\    .file-path { flex: 1; font-family: monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text); }
        \\    .file-old-path { font-size: 11px; color: var(--text2); font-family: monospace; }
        \\    .badge { display: inline-flex; align-items: center; justify-content: center; width: 20px; height: 20px; border-radius: 4px; font-size: 11px; font-weight: 700; flex-shrink: 0; }
        \\    .badge-modified { background: #fff3cd; color: #856404; }
        \\    .badge-staged { background: #cff4fc; color: #055160; }
        \\    .badge-added { background: #d1e7dd; color: #0a3622; }
        \\    .badge-deleted { background: #f8d7da; color: #58151c; }
        \\    .badge-staged-del { background: #f8d7da; color: #58151c; }
        \\    .badge-renamed { background: #cfe2ff; color: #084298; }
        \\    .badge-untracked { background: #e2e3e5; color: #41464b; }
        \\    .stage-btn { width: 24px; height: 24px; border: none; border-radius: 4px; cursor: pointer; font-size: 16px; font-weight: bold; flex-shrink: 0; transition: all 0.2s; display: flex; align-items: center; justify-content: center; }
        \\    .stage-btn:hover { transform: scale(1.1); }
        \\    .stage-btn.add { background: #d1e7dd; color: #0a3622; }
        \\    .stage-btn.add:hover { background: #a3cfbb; }
        \\    .stage-btn.remove { background: #f8d7da; color: #58151c; }
        \\    .stage-btn.remove:hover { background: #f1aeb5; }
        \\    .stage-btn.restore { background: #fff3cd; color: #856404; }
        \\    .stage-btn.restore:hover { background: #ffc107; color: #000; }
        \\    .commit-section { border-top: 1px solid var(--border); padding: 0.75em 1em; background: var(--bg2); }
        \\    .commit-section-title { font-weight: 600; font-size: 13px; color: var(--text2); text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 8px; display: flex; align-items: center; gap: 6px; }
        \\    .commit-textarea { width: 100%; min-height: 60px; max-height: 120px; padding: 8px; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); color: var(--text); font-family: inherit; font-size: 13px; resize: vertical; margin-bottom: 8px; }
        \\    .commit-textarea:focus { outline: none; border-color: var(--link); box-shadow: 0 0 0 2px rgba(9,105,218,0.15); }
        \\    .commit-textarea::placeholder { color: var(--text2); }
        \\    .commit-btn { width: 100%; padding: 8px 16px; background: #2d6a4f; color: white; border: none; border-radius: 6px; font-size: 13px; font-weight: 600; cursor: pointer; transition: background 0.2s, opacity 0.2s; display: flex; align-items: center; justify-content: center; gap: 6px; }
        \\    .commit-btn:hover { background: #1b4332; }
        \\    .commit-btn:disabled { opacity: 0.5; cursor: not-allowed; }
        \\    .commit-feedback { font-size: 12px; margin-top: 8px; padding: 6px 8px; border-radius: 4px; display: none; }
        \\    .commit-feedback.success { display: block; background: var(--add-bg); color: var(--add-text); }
        \\    .commit-feedback.error { display: block; background: var(--del-bg); color: var(--del-text); }
        \\    .push-section { border-top: 1px solid var(--border); padding: 0.75em 1em; background: var(--bg2); }
        \\    .push-section-title { font-weight: 600; font-size: 13px; color: var(--text2); text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 8px; display: flex; align-items: center; gap: 6px; }
        \\    .push-row { display: flex; gap: 8px; align-items: center; }
        \\    .push-select { flex: 1; padding: 6px 8px; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); color: var(--text); font-size: 13px; }
        \\    .push-select:focus { outline: none; border-color: var(--link); }
        \\    .push-btn { padding: 6px 16px; background: #0969da; color: white; border: none; border-radius: 6px; font-size: 13px; font-weight: 600; cursor: pointer; transition: background 0.2s, opacity 0.2s; white-space: nowrap; }
        \\    .push-btn:hover { background: #0550ae; }
        \\    .push-btn:disabled { opacity: 0.5; cursor: not-allowed; }
        \\    .push-feedback { font-size: 12px; margin-top: 8px; padding: 6px 8px; border-radius: 4px; display: none; }
        \\    .push-feedback.success { display: block; background: var(--add-bg); color: var(--add-text); }
        \\    .push-feedback.error { display: block; background: var(--del-bg); color: var(--del-text); }
        \\    .log-section { border-top: 1px solid var(--border); }
        \\    .log-toggle { width: 100%; padding: 8px 12px; background: var(--bg3); border: none; border-bottom: 1px solid var(--border); color: var(--text2); font-size: 12px; font-weight: 600; text-align: left; cursor: pointer; text-transform: uppercase; letter-spacing: 0.05em; display: flex; justify-content: space-between; align-items: center; }
        \\    .log-toggle:hover { background: var(--hover); }
        \\    .log-content { display: none; overflow-y: auto; max-height: 200px; }
        \\    .log-content.open { display: block; }
        \\    .commit-item { display: flex; align-items: flex-start; gap: 6px; padding: 6px 12px; cursor: pointer; border-bottom: 1px solid var(--border); transition: background 0.15s; font-size: 11px; font-family: monospace; line-height: 1.4; }
        \\    .commit-item:hover { background: var(--hover); }
        \\    .commit-item.active { background: var(--hover); border-left: 3px solid #2d6a4f; padding-left: 9px; }
        \\    .commit-graph { color: var(--text2); white-space: pre; flex-shrink: 0; }
        \\    .commit-hash { color: #0969da; font-weight: 600; flex-shrink: 0; }
        \\    .commit-message { color: var(--text); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        \\    .diff-panel { flex: 1; overflow: hidden; display: flex; flex-direction: column; background: var(--bg); }
        \\    .diff-header { padding: 0.75em 1em; border-bottom: 1px solid var(--border); font-size: 13px; color: var(--text2); background: var(--bg3); display: flex; align-items: center; gap: 8px; }
        \\    .diff-filename { font-family: monospace; color: var(--text); font-weight: 500; }
        \\    .diff-body { flex: 1; overflow: auto; }
        \\    .diff-empty { display: flex; align-items: center; justify-content: center; height: 100%; color: var(--text2); font-size: 14px; flex-direction: column; gap: 12px; }
        \\    .diff-empty-icon { font-size: 48px; }
        \\    .diff-loading { display: flex; align-items: center; justify-content: center; height: 100%; color: var(--text2); font-size: 14px; gap: 10px; }
        \\    .spinner { width: 24px; height: 24px; border: 2px solid var(--border); border-top-color: #2d6a4f; border-radius: 50%; animation: spin 0.8s linear infinite; }
        \\    @keyframes spin { to { transform: rotate(360deg); } }
        \\    table.diff-table { width: 100%; border-collapse: collapse; font-family: monospace; font-size: 13px; }
        \\    .diff-table td { padding: 1px 8px; white-space: pre-wrap; word-break: break-all; vertical-align: top; }
        \\    .diff-table .ln { width: 1%; min-width: 40px; text-align: right; color: var(--text2); user-select: none; border-right: 1px solid var(--border); padding-right: 8px; }
        \\    .diff-add { background: var(--add-bg); color: var(--add-text); }
        \\    .diff-del { background: var(--del-bg); color: var(--del-text); }
        \\    .diff-hunk { background: var(--hunk-bg); color: var(--hunk-text); }
        \\    .diff-meta { background: var(--meta-bg); color: var(--meta-text); }
        \\    .diff-ctx { background: var(--bg); color: var(--text); }
        \\    .no-changes { padding: 2em; color: var(--text2); font-size: 14px; }
        \\    @media (max-width: 700px) {
        \\      .layout { flex-direction: column; height: auto; min-height: 100vh; }
        \\      .sidebar { width: 100%; max-width: 100%; height: auto; max-height: 50vh; border-right: none; border-bottom: 1px solid var(--border); overflow-y: auto; flex-shrink: 0; }
        \\      .diff-panel { flex: 1; min-height: 50vh; }
        \\      .sidebar-header { padding: 12px 16px; font-size: 14px; min-height: 44px; }
        \\      .file-item { padding: 12px 16px; min-height: 44px; }
        \\      .log-toggle { padding: 12px 16px; font-size: 13px; min-height: 44px; }
        \\      .commit-item { padding: 10px 12px; min-height: 40px; }
        \\      .stage-btn { width: 32px; height: 32px; font-size: 18px; }
        \\      .header { flex-wrap: wrap; gap: 8px; padding: 0.6em 1em; }
        \\      .header-right { gap: 6px; }
        \\      .commit-section, .push-section, .log-section { padding: 0.6em 1em; }
        \\    }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="header">
        \\    <h1>🌿 Git Status</h1>
        \\    <div class="header-right">
        \\      <span class="branch-badge">⎇ 
    );
    try appendEscaped(&html, allocator, status.branch);
    try html.appendSlice(allocator,
        \\</span>
        \\      <a href="/
    );
    // Back URL: root → "/", subdirectory → "/<dir_path>/"
    if (!is_root) {
        try html.appendSlice(allocator, dir_path);
        try html.append(allocator, '/');
    }
    try html.appendSlice(allocator,
        \\" class="back-btn">← Back</a>
        \\      <button class="theme-toggle" id="themeToggle" onclick="toggleTheme()">🌙 Dark</button>
        \\    </div>
        \\  </div>
        \\  <div class="layout">
        \\    <div class="sidebar">
    );

    // Separate files into staged and unstaged
    var staged_files = std.ArrayList(struct { file: git.GitFile, index: usize }).initCapacity(allocator, status.files.len) catch return error.OutOfMemory;
    defer staged_files.deinit(allocator);
    var unstaged_files = std.ArrayList(struct { file: git.GitFile, index: usize }).initCapacity(allocator, status.files.len) catch return error.OutOfMemory;
    defer unstaged_files.deinit(allocator);

    for (status.files, 0..) |f, i| {
        const is_staged = f.status == .staged_modified or f.status == .staged_added or f.status == .staged_deleted;
        if (is_staged) {
            try staged_files.append(allocator, .{ .file = f, .index = i });
        } else {
            try unstaged_files.append(allocator, .{ .file = f, .index = i });
        }
    }

    // Render Staged Changes section
    try html.appendSlice(allocator, "      <button class=\"sidebar-header\" onclick=\"toggleFileSection(this, 'stagedFiles')\">Staged Changes (");
    var staged_count_buf: [32]u8 = undefined;
    const staged_count_str = std.fmt.bufPrint(&staged_count_buf, "{d}", .{staged_files.items.len}) catch "?";
    try html.appendSlice(allocator, staged_count_str);
    try html.appendSlice(allocator, ") <span>▼</span></button>\n      <div class=\"file-list-container\" id=\"stagedFiles\">\n");

    if (staged_files.items.len == 0) {
        try html.appendSlice(allocator, "        <div class=\"file-list no-changes\">No staged changes</div>\n");
    } else {
        try html.appendSlice(allocator, "        <div class=\"file-list\">\n");
        for (staged_files.items) |item| {
            const f = item.file;
            const i = item.index;
            const badge = statusBadge(f.status);
            try html.appendSlice(allocator, "        <div class=\"file-item\" id=\"fi-");
            var idx_buf: [32]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch "0";
            try html.appendSlice(allocator, idx_str);
            try html.appendSlice(allocator, "\" onclick=\"loadDiff(");
            try html.appendSlice(allocator, idx_str);
            try html.appendSlice(allocator, ", '");
            // JS-escape the path (single quotes)
            for (f.path) |c| {
                switch (c) {
                    '\\' => try html.appendSlice(allocator, "\\\\"),
                    '\'' => try html.appendSlice(allocator, "\\'"),
                    else => try html.append(allocator, c),
                }
            }
            try html.appendSlice(allocator, "', false)\">\n");
            try html.appendSlice(allocator, "          <span class=\"badge ");
            try html.appendSlice(allocator, badge.class);
            try html.appendSlice(allocator, "\">");
            try html.appendSlice(allocator, badge.label);
            try html.appendSlice(allocator, "</span>\n");
            try html.appendSlice(allocator, "          <div style=\"flex:1;overflow:hidden\">\n");
            try html.appendSlice(allocator, "            <div class=\"file-path\">");
            try appendEscaped(&html, allocator, f.path);
            try html.appendSlice(allocator, "</div>\n");
            if (f.old_path) |op| {
                try html.appendSlice(allocator, "            <div class=\"file-old-path\">← ");
                try appendEscaped(&html, allocator, op);
                try html.appendSlice(allocator, "</div>\n");
            }
            try html.appendSlice(allocator, "          </div>\n");
            try html.appendSlice(allocator, "          <button class=\"stage-btn remove\" onclick=\"event.stopPropagation(); unstageFile('");
            for (f.path) |c| {
                switch (c) {
                    '\\' => try html.appendSlice(allocator, "\\\\"),
                    '\'' => try html.appendSlice(allocator, "\\'"),
                    else => try html.append(allocator, c),
                }
            }
            try html.appendSlice(allocator, "')\" title=\"Unstage file\">−</button>\n");
            try html.appendSlice(allocator, "        </div>\n");
        }
        try html.appendSlice(allocator, "        </div>\n");
    }

    try html.appendSlice(allocator, "      </div>\n");

    // Render Changes section
    try html.appendSlice(allocator, "      <button class=\"sidebar-header\" style=\"border-top: 1px solid var(--border);\" onclick=\"toggleFileSection(this, 'unstagedFiles')\">Changes (");
    var unstaged_count_buf: [32]u8 = undefined;
    const unstaged_count_str = std.fmt.bufPrint(&unstaged_count_buf, "{d}", .{unstaged_files.items.len}) catch "?";
    try html.appendSlice(allocator, unstaged_count_str);
    try html.appendSlice(allocator, ") <span>▼</span></button>\n      <div class=\"file-list-container\" id=\"unstagedFiles\">\n");

    if (unstaged_files.items.len == 0) {
        try html.appendSlice(allocator, "        <div class=\"file-list no-changes\">No unstaged changes</div>\n");
    } else {
        try html.appendSlice(allocator, "        <div class=\"file-list\">\n");
        for (unstaged_files.items) |item| {
            const f = item.file;
            const i = item.index;
            const badge = statusBadge(f.status);
            const is_untracked = f.status == .untracked;
            try html.appendSlice(allocator, "        <div class=\"file-item\" id=\"fi-");
            var idx_buf: [32]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch "0";
            try html.appendSlice(allocator, idx_str);
            try html.appendSlice(allocator, "\" onclick=\"loadDiff(");
            try html.appendSlice(allocator, idx_str);
            try html.appendSlice(allocator, ", '");
            // JS-escape the path (single quotes)
            for (f.path) |c| {
                switch (c) {
                    '\\' => try html.appendSlice(allocator, "\\\\"),
                    '\'' => try html.appendSlice(allocator, "\\'"),
                    else => try html.append(allocator, c),
                }
            }
            try html.appendSlice(allocator, "', ");
            try html.appendSlice(allocator, if (is_untracked) "true" else "false");
            try html.appendSlice(allocator, ")\">\n");
            try html.appendSlice(allocator, "          <span class=\"badge ");
            try html.appendSlice(allocator, badge.class);
            try html.appendSlice(allocator, "\">");
            try html.appendSlice(allocator, badge.label);
            try html.appendSlice(allocator, "</span>\n");
            try html.appendSlice(allocator, "          <div style=\"flex:1;overflow:hidden\">\n");
            try html.appendSlice(allocator, "            <div class=\"file-path\">");
            try appendEscaped(&html, allocator, f.path);
            try html.appendSlice(allocator, "</div>\n");
            if (f.old_path) |op| {
                try html.appendSlice(allocator, "            <div class=\"file-old-path\">← ");
                try appendEscaped(&html, allocator, op);
                try html.appendSlice(allocator, "</div>\n");
            }
            try html.appendSlice(allocator, "          </div>\n");
            if (!is_untracked) {
                try html.appendSlice(allocator, "          <button class=\"stage-btn restore\" onclick=\"event.stopPropagation(); restoreFile('");
                for (f.path) |c| {
                    switch (c) {
                        '\\' => try html.appendSlice(allocator, "\\\\"),
                        '\'' => try html.appendSlice(allocator, "\\'"),
                        else => try html.append(allocator, c),
                    }
                }
                try html.appendSlice(allocator, "')\" title=\"Discard changes\">↩</button>\n");
            }
            try html.appendSlice(allocator, "          <button class=\"stage-btn add\" onclick=\"event.stopPropagation(); stageFile('");
            for (f.path) |c| {
                switch (c) {
                    '\\' => try html.appendSlice(allocator, "\\\\"),
                    '\'' => try html.appendSlice(allocator, "\\'"),
                    else => try html.append(allocator, c),
                }
            }
            try html.appendSlice(allocator, "')\" title=\"Stage file\">+</button>\n");
            try html.appendSlice(allocator, "        </div>\n");
        }
        try html.appendSlice(allocator, "        </div>\n");
    }

    try html.appendSlice(allocator, "      </div>\n");

    // Commit section
    try html.appendSlice(allocator,
        \\      <div class="commit-section">
        \\        <div class="commit-section-title">📝 Commit</div>
        \\        <textarea class="commit-textarea" id="commitMessage" placeholder="Commit message..." rows="3"></textarea>
        \\        <button class="commit-btn" id="commitBtn" onclick="commitStaged()" disabled>
        \\          Commit Staged
        \\        </button>
        \\        <div class="commit-feedback" id="commitFeedback"></div>
        \\      </div>
    );

    // Push section
    try html.appendSlice(allocator,
        \\      <div class="push-section">
        \\        <div class="push-section-title">🚀 Push</div>
        \\        <div class="push-row">
        \\          <select class="push-select" id="remoteSelect">
        \\            <option value="">Loading remotes...</option>
        \\          </select>
        \\          <button class="push-btn" id="pushBtn" onclick="pushToRemote()" disabled>
        \\            Push
        \\          </button>
        \\        </div>
        \\        <div class="push-feedback" id="pushFeedback"></div>
        \\      </div>
    );

    // Recent commits section
    try html.appendSlice(allocator,
        \\      <div class="log-section">
        \\        <button class="log-toggle" onclick="toggleLog(this)">
        \\          Recent Commits <span>▶</span>
        \\        </button>
        \\        <div class="log-content" id="logContent">
    );
    try appendEscaped(&html, allocator, log_text);
    try html.appendSlice(allocator,
        \\        </div>
        \\      </div>
        \\    </div>
    ); // end sidebar

    // Diff panel
    try html.appendSlice(allocator,
        \\    <div class="diff-panel">
        \\      <div class="diff-header" id="diffHeader">
        \\        <span style="color:var(--text2)">Select a file to view its diff</span>
        \\      </div>
        \\      <div class="diff-body" id="diffBody">
        \\        <div class="diff-empty">
        \\          <div class="diff-empty-icon">📂</div>
        \\          <div>Click a file on the left to view its diff</div>
        \\        </div>
        \\      </div>
        \\    </div>
        \\  </div>
        \\
        \\  <script>
        \\    const GIT_ROOT = '
    );
    // Inject the dir_path as a JS string literal (escape single quotes and backslashes)
    for (dir_path) |c| {
        switch (c) {
            '\\' => try html.appendSlice(allocator, "\\\\"),
            '\'' => try html.appendSlice(allocator, "\\'"),
            else => try html.append(allocator, c),
        }
    }
    try html.appendSlice(allocator,
        \\';
        \\    const GIT_ROOT_ABS = '
    );
    // Inject git_root_abs if present, otherwise empty string
    if (git_root_abs) |abs| {
        for (abs) |c| {
            switch (c) {
                '\\' => try html.appendSlice(allocator, "\\\\"),
                '\'' => try html.appendSlice(allocator, "\\'"),
                else => try html.append(allocator, c),
            }
        }
    }
    try html.appendSlice(allocator,
        \\';
        \\    const BRANCH_NAME = '
    );
    // Inject the branch name as a JS string literal
    for (status.branch) |c| {
        switch (c) {
            '\\' => try html.appendSlice(allocator, "\\\\"),
            '\'' => try html.appendSlice(allocator, "\\'"),
            else => try html.append(allocator, c),
        }
    }
    try html.appendSlice(allocator,
        \\';
        \\    function gitRootParam() {
        \\      if (GIT_ROOT_ABS) return '&git_root_abs=' + encodeURIComponent(GIT_ROOT_ABS);
        \\      return '&root=' + encodeURIComponent(GIT_ROOT);
        \\    }
        \\    // Theme
        \\    function initTheme() {
        \\      const saved = localStorage.getItem('theme');
        \\      if (saved === 'dark') document.body.classList.add('dark-mode');
        \\      else if (!saved && window.matchMedia('(prefers-color-scheme: dark)').matches) document.body.classList.add('dark-mode');
        \\      updateThemeToggle();
        \\    }
        \\    function toggleTheme() {
        \\      const isDark = document.body.classList.toggle('dark-mode');
        \\      localStorage.setItem('theme', isDark ? 'dark' : 'light');
        \\      updateThemeToggle();
        \\    }
        \\    function updateThemeToggle() {
        \\      const btn = document.getElementById('themeToggle');
        \\      if (btn) btn.textContent = document.body.classList.contains('dark-mode') ? '☀️ Light' : '🌙 Dark';
        \\    }
        \\    // Log toggle
        \\    function toggleLog(btn) {
        \\      const content = document.getElementById('logContent');
        \\      const arrow = btn.querySelector('span');
        \\      content.classList.toggle('open');
        \\      arrow.textContent = content.classList.contains('open') ? '▼' : '▶';
        \\      if (content.classList.contains('open') && !content.dataset.rendered) {
        \\        renderCommits();
        \\        content.dataset.rendered = 'true';
        \\      }
        \\    }
        \\    // File section toggle
        \\    function toggleFileSection(btn, contentId) {
        \\      const content = document.getElementById(contentId);
        \\      const arrow = btn.querySelector('span');
        \\      content.classList.toggle('collapsed');
        \\      arrow.textContent = content.classList.contains('collapsed') ? '▶' : '▼';
        \\    }
        \\    // Active file tracking
        \\    let activeIdx = -1;
        \\    function loadDiff(idx, filePath, isUntracked) {
        \\      if (activeIdx >= 0) {
        \\        const prev = document.getElementById('fi-' + activeIdx);
        \\        if (prev) prev.classList.remove('active');
        \\      }
        \\      activeIdx = idx;
        \\      const el = document.getElementById('fi-' + idx);
        \\      if (el) el.classList.add('active');
        \\      const header = document.getElementById('diffHeader');
        \\      const body = document.getElementById('diffBody');
        \\      header.innerHTML = '<span class="diff-filename">' + escHtml(filePath) + '</span>';
        \\      body.innerHTML = '<div class="diff-loading"><div class="spinner"></div>Loading diff...</div>';
        \\      fetch('/__git__/diff?file=' + encodeURIComponent(filePath) + '&untracked=' + (isUntracked ? '1' : '0') + gitRootParam())
        \\        .then(r => r.text())
        \\        .then(text => { body.innerHTML = renderDiff(text); })
        \\        .catch(err => { body.innerHTML = '<div class="no-changes">Error loading diff: ' + escHtml(err.message) + '</div>'; });
        \\    }
        \\    function loadCommitDiff(hash, commitEl) {
        \\      if (activeIdx >= 0) {
        \\        const prev = document.getElementById('fi-' + activeIdx);
        \\        if (prev) prev.classList.remove('active');
        \\        activeIdx = -1;
        \\      }
        \\      const prevCommit = document.querySelector('.commit-item.active');
        \\      if (prevCommit) prevCommit.classList.remove('active');
        \\      if (commitEl) commitEl.classList.add('active');
        \\      const header = document.getElementById('diffHeader');
        \\      const body = document.getElementById('diffBody');
        \\      header.innerHTML = '<span class="diff-filename">Commit: ' + escHtml(hash) + '</span>';
        \\      body.innerHTML = '<div class="diff-loading"><div class="spinner"></div>Loading commit diff...</div>';
        \\      fetch('/__git__/commit-diff?hash=' + encodeURIComponent(hash) + gitRootParam())
        \\        .then(r => r.text())
        \\        .then(text => { body.innerHTML = renderDiff(text); })
        \\        .catch(err => { body.innerHTML = '<div class="no-changes">Error loading commit diff: ' + escHtml(err.message) + '</div>'; });
        \\    }
        \\    // Stage/Unstage operations
        \\    function stageFile(filePath) {
        \\      fetch('/__git__/stage?file=' + encodeURIComponent(filePath) + gitRootParam(), {
        \\        method: 'POST'
        \\      })
        \\        .then(r => r.json())
        \\        .then(data => {
        \\          if (data.success) {
        \\            location.reload();
        \\          } else {
        \\            alert('Failed to stage file');
        \\          }
        \\        })
        \\        .catch(err => {
        \\          alert('Error staging file: ' + err.message);
        \\        });
        \\    }
        \\    function unstageFile(filePath) {
        \\      fetch('/__git__/unstage?file=' + encodeURIComponent(filePath) + gitRootParam(), {
        \\        method: 'POST'
        \\      })
        \\        .then(r => r.json())
        \\        .then(data => {
        \\          if (data.success) {
        \\            location.reload();
        \\          } else {
        \\            alert('Failed to unstage file');
        \\          }
        \\        })
        \\        .catch(err => {
        \\          alert('Error unstaging file: ' + err.message);
        \\        });
        \\    }
        \\    function restoreFile(filePath) {
        \\      if (!confirm('Discard all changes to "' + filePath + '"?\n\nThis cannot be undone.')) return;
        \\      fetch('/__git__/restore?file=' + encodeURIComponent(filePath) + gitRootParam(), {
        \\        method: 'POST'
        \\      })
        \\        .then(r => r.json())
        \\        .then(data => {
        \\          if (data.success) {
        \\            location.reload();
        \\          } else {
        \\            alert('Failed to restore file: ' + filePath);
        \\          }
        \\        })
        \\        .catch(err => {
        \\          alert('Error restoring file: ' + err.message);
        \\        });
        \\    }
        \\    // Commit operation
        \\    function commitStaged() {
        \\      const messageEl = document.getElementById('commitMessage');
        \\      const btnEl = document.getElementById('commitBtn');
        \\      const feedbackEl = document.getElementById('commitFeedback');
        \\      const message = messageEl.value.trim();
        \\      if (!message) {
        \\        feedbackEl.className = 'commit-feedback error';
        \\        feedbackEl.textContent = 'Please enter a commit message';
        \\        return;
        \\      }
        \\      btnEl.disabled = true;
        \\      btnEl.textContent = 'Committing...';
        \\      feedbackEl.className = 'commit-feedback';
        \\      feedbackEl.style.display = 'none';
        \\      fetch('/__git__/commit' + gitRootParam(), {
        \\        method: 'POST',
        \\        headers: { 'Content-Type': 'application/json' },
        \\        body: JSON.stringify({ message: message })
        \\      })
        \\        .then(r => r.json())
        \\        .then(data => {
        \\          if (data.success) {
        \\            feedbackEl.className = 'commit-feedback success';
        \\            feedbackEl.textContent = 'Commit successful!';
        \\            messageEl.value = '';
        \\            setTimeout(() => location.reload(), 1000);
        \\          } else {
        \\            feedbackEl.className = 'commit-feedback error';
        \\            feedbackEl.textContent = 'Commit failed: ' + (data.error || 'Unknown error');
        \\          }
        \\        })
        \\        .catch(err => {
        \\          feedbackEl.className = 'commit-feedback error';
        \\          feedbackEl.textContent = 'Error: ' + err.message;
        \\        })
        \\        .finally(() => {
        \\          btnEl.disabled = false;
        \\          btnEl.textContent = 'Commit Staged';
        \\        });
        \\    }
        \\    // Push operation
        \\    function pushToRemote() {
        \\      const selectEl = document.getElementById('remoteSelect');
        \\      const btnEl = document.getElementById('pushBtn');
        \\      const feedbackEl = document.getElementById('pushFeedback');
        \\      const remote = selectEl.value;
        \\      if (!remote) {
        \\        feedbackEl.className = 'push-feedback error';
        \\        feedbackEl.textContent = 'Please select a remote';
        \\        return;
        \\      }
        \\      btnEl.disabled = true;
        \\      btnEl.textContent = 'Pushing...';
        \\      feedbackEl.className = 'push-feedback';
        \\      feedbackEl.style.display = 'none';
        \\      fetch('/__git__/push' + gitRootParam(), {
        \\        method: 'POST',
        \\        headers: { 'Content-Type': 'application/json' },
        \\        body: JSON.stringify({ remote: remote, branch: BRANCH_NAME })
        \\      })
        \\        .then(r => r.json())
        \\        .then(data => {
        \\          if (data.success) {
        \\            feedbackEl.className = 'push-feedback success';
        \\            feedbackEl.textContent = 'Push successful!';
        \\          } else {
        \\            feedbackEl.className = 'push-feedback error';
        \\            feedbackEl.textContent = 'Push failed: ' + (data.error || 'Unknown error');
        \\          }
        \\        })
        \\        .catch(err => {
        \\          feedbackEl.className = 'push-feedback error';
        \\          feedbackEl.textContent = 'Error: ' + err.message;
        \\        })
        \\        .finally(() => {
        \\          btnEl.disabled = false;
        \\          btnEl.textContent = 'Push';
        \\        });
        \\    }
        \\    // Load remotes on page load
        \\    function loadRemotes() {
        \\      fetch('/__git__/remotes' + gitRootParam())
        \\        .then(r => r.json())
        \\        .then(data => {
        \\          const selectEl = document.getElementById('remoteSelect');
        \\          selectEl.innerHTML = '';
        \\          if (data.remotes && data.remotes.length > 0) {
        \\            for (const remote of data.remotes) {
        \\              const opt = document.createElement('option');
        \\              opt.value = remote;
        \\              opt.textContent = remote;
        \\              if (remote === 'origin') opt.selected = true;
        \\              selectEl.appendChild(opt);
        \\            }
        \\            document.getElementById('pushBtn').disabled = false;
        \\          } else {
        \\            const opt = document.createElement('option');
        \\            opt.value = '';
        \\            opt.textContent = 'No remotes found';
        \\            selectEl.appendChild(opt);
        \\          }
        \\        })
        \\        .catch(() => {
        \\          const selectEl = document.getElementById('remoteSelect');
        \\          selectEl.innerHTML = '<option value="">Error loading remotes</option>';
        \\        });
        \\    }
        \\    // Update commit button state based on staged files
        \\    function updateCommitState() {
        \\      const hasStaged = document.querySelectorAll('#stagedFiles .file-item').length > 0;
        \\      const commitBtn = document.getElementById('commitBtn');
        \\      if (commitBtn) commitBtn.disabled = !hasStaged;
        \\    }
        \\    function renderCommits() {
        \\      const logContent = document.getElementById('logContent');
        \\      const rawText = logContent.textContent;
        \\      logContent.innerHTML = '';
        \\      const lines = rawText.split('\n');
        \\      for (let line of lines) {
        \\        if (!line.trim()) continue;
        \\        const match = line.match(/^([*|\/ \\]+)\s*([a-f0-9]{7,})\s+(.*)$/);
        \\        if (match) {
        \\          const graph = match[1];
        \\          const hash = match[2];
        \\          const message = match[3];
        \\          const div = document.createElement('div');
        \\          div.className = 'commit-item';
        \\          div.onclick = () => loadCommitDiff(hash, div);
        \\          div.innerHTML = '<span class="commit-graph">' + escHtml(graph) + '</span>' +
        \\                          '<span class="commit-hash">' + escHtml(hash) + '</span>' +
        \\                          '<span class="commit-message">' + escHtml(message) + '</span>';
        \\          logContent.appendChild(div);
        \\        }
        \\      }
        \\    }
        \\    function escHtml(s) {
        \\      return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
        \\    }
        \\    function renderDiff(text) {
        \\      if (!text || text.trim() === '' || text === '(no diff available)') {
        \\        return '<div class="no-changes">No diff available for this file.</div>';
        \\      }
        \\      const lines = text.split('\n');
        \\      let html = '<table class="diff-table"><tbody>';
        \\      let addLn = 0, delLn = 0, ctxLn = 0;
        \\      for (let i = 0; i < lines.length; i++) {
        \\        const line = lines[i];
        \\        let cls, ln;
        \\        if (line.startsWith('diff ') || line.startsWith('index ') || line.startsWith('--- ') || line.startsWith('+++ ')) {
        \\          cls = 'diff-meta'; ln = '';
        \\        } else if (line.startsWith('@@')) {
        \\          cls = 'diff-hunk'; ln = '@@';
        \\          // Parse hunk header for line numbers
        \\          const m = line.match(/@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
        \\          if (m) { delLn = parseInt(m[1]); addLn = parseInt(m[2]); }
        \\        } else if (line.startsWith('+')) {
        \\          cls = 'diff-add'; ln = '+' + addLn; addLn++;
        \\        } else if (line.startsWith('-')) {
        \\          cls = 'diff-del'; ln = '-' + delLn; delLn++;
        \\        } else {
        \\          cls = 'diff-ctx'; ln = ctxLn > 0 ? String(addLn) : ''; addLn++; delLn++;
        \\        }
        \\        html += '<tr class="' + cls + '"><td class="ln">' + escHtml(String(ln)) + '</td><td>' + escHtml(line) + '</td></tr>';
        \\      }
        \\      html += '</tbody></table>';
        \\      return html;
        \\    }
        \\    initTheme();
        \\    loadRemotes();
        \\    updateCommitState();
        \\  </script>
        \\</body></html>
    );

    try w.writeAll(html.items);
    try w.flush();
}

/// Serve the diff for a single file as plain text (for AJAX).
/// `git_dir` is the resolved git root directory (already opened by caller).
pub fn serveGitDiff(io: Io, allocator: std.mem.Allocator, stream: Io.net.Stream, git_dir: Io.Dir, file_path: []const u8, is_untracked: bool) !void {
    const diff = git.getFileDiff(io, allocator, git_dir, file_path, is_untracked) catch |err| {
        std.debug.print("Failed to get diff for {s}: {s}\n", .{ file_path, @errorName(err) });
        try http.sendErrorResponse(stream, io, .internal_server_error, "Failed to get diff");
        return;
    };
    defer allocator.free(diff);

    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/plain; charset=utf-8" },
    });

    var write_buf: [65536]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    try stream_writer.interface.writeAll(diff);
    try stream_writer.interface.flush();
}

/// Serve the diff for a specific commit as plain text (for AJAX).
/// `git_dir` is the resolved git root directory (already opened by caller).
pub fn serveCommitDiff(io: Io, allocator: std.mem.Allocator, stream: Io.net.Stream, git_dir: Io.Dir, commit_hash: []const u8) !void {
    const diff = git.getCommitDiff(io, allocator, git_dir, commit_hash) catch |err| {
        std.debug.print("Failed to get commit diff for {s}: {s}\n", .{ commit_hash, @errorName(err) });
        try http.sendErrorResponse(stream, io, .internal_server_error, "Failed to get commit diff");
        return;
    };
    defer allocator.free(diff);

    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/plain; charset=utf-8" },
    });

    var write_buf: [65536]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    try stream_writer.interface.writeAll(diff);
    try stream_writer.interface.flush();
}
