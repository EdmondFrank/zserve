const std = @import("std");
const Io = std.Io;
const url = @import("url.zig");

/// HTML template for Markdown preview page
/// Usage in Zig: format with the following arguments:
///   {0s} = page title (filename)
///   {1s} = parent directory URL
///   {2s} = filename
///   {3s} = file size string
///   {4s} = mime type
///   {5s} = raw markdown content (JS-escaped for rendering)
///   {6s} = raw markdown content (HTML-escaped for source view)
pub const markdown_preview_template =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <meta name="color-scheme" content="light dark">
    \\  <title>{0s} - Markdown Preview</title>
    \\  <!-- Marked.js for Markdown rendering -->
    \\  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
    \\  <!-- Highlight.js for syntax highlighting -->
    \\  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css" id="hljs-theme">
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/bash.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/zig.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/rust.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/go.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/python.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/javascript.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/typescript.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/json.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/yaml.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/xml.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/css.min.js"></script>
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/sql.min.js"></script>
    \\  <style>
    \\    :root {{
    \\      --bg-color: #ffffff;
    \\      --text-color: #24292e;
    \\      --text-secondary: #666;
    \\      --border-color: #e2e8f0;
    \\      --link-color: #0366d6;
    \\      --hover-bg: #e5e7eb;
    \\      --header-gradient-start: #3b82f6;
    \\      --header-gradient-end: #2563eb;
    \\      --header-text: #ffffff;
    \\      --sidebar-bg: #f8fafc;
    \\      --sidebar-border: #e2e8f0;
    \\      --toc-link-color: #475569;
    \\      --toc-link-hover: #1e293b;
    \\      --toc-active-bg: #eff6ff;
    \\      --toc-active-border: #3b82f6;
    \\      --code-bg: #f6f8fa;
    \\      --code-border: #d0d7de;
    \\      --blockquote-border: #d0d7de;
    \\      --blockquote-bg: #f6f8fa;
    \\      --table-border: #d0d7de;
    \\      --table-header-bg: #f6f8fa;
    \\      --table-row-alt: #f6f8fa;
    \\      --hr-color: #d0d7de;
    \\      --kbd-bg: #f6f8fa;
    \\      --kbd-border: #d0d7de;
    \\      --btn-bg: #f1f5f9;
    \\      --btn-border: #cbd5e1;
    \\      --btn-color: #475569;
    \\      --btn-hover-bg: #e2e8f0;
    \\      --btn-active-bg: #3b82f6;
    \\      --btn-active-color: #ffffff;
    \\      --meta-bg: #f8fafc;
    \\      --source-bg: #f6f8fa;
    \\      --scrollbar-thumb: #cbd5e1;
    \\      --scrollbar-track: #f1f5f9;
    \\    }}
    \\    @media (prefers-color-scheme: dark) {{
    \\      :root {{
    \\        --bg-color: #0d1117;
    \\        --text-color: #c9d1d9;
    \\        --text-secondary: #8b949e;
    \\        --border-color: #30363d;
    \\        --link-color: #58a6ff;
    \\        --hover-bg: #21262d;
    \\        --header-gradient-start: #3b82f6;
    \\        --header-gradient-end: #2563eb;
    \\        --header-text: #ffffff;
    \\        --sidebar-bg: #161b22;
    \\        --sidebar-border: #30363d;
    \\        --toc-link-color: #8b949e;
    \\        --toc-link-hover: #c9d1d9;
    \\        --toc-active-bg: #1f2937;
    \\        --toc-active-border: #3b82f6;
    \\        --code-bg: #161b22;
    \\        --code-border: #30363d;
    \\        --blockquote-border: #30363d;
    \\        --blockquote-bg: #161b22;
    \\        --table-border: #30363d;
    \\        --table-header-bg: #161b22;
    \\        --table-row-alt: #0d1117;
    \\        --hr-color: #30363d;
    \\        --kbd-bg: #161b22;
    \\        --kbd-border: #30363d;
    \\        --btn-bg: #21262d;
    \\        --btn-border: #30363d;
    \\        --btn-color: #c9d1d9;
    \\        --btn-hover-bg: #30363d;
    \\        --btn-active-bg: #3b82f6;
    \\        --btn-active-color: #ffffff;
    \\        --meta-bg: #161b22;
    \\        --source-bg: #161b22;
    \\        --scrollbar-thumb: #30363d;
    \\        --scrollbar-track: #0d1117;
    \\      }}
    \\    }}
    \\    body.dark-mode {{
    \\      --bg-color: #0d1117;
    \\      --text-color: #c9d1d9;
    \\      --text-secondary: #8b949e;
    \\      --border-color: #30363d;
    \\      --link-color: #58a6ff;
    \\      --hover-bg: #21262d;
    \\      --header-gradient-start: #3b82f6;
    \\      --header-gradient-end: #2563eb;
    \\      --header-text: #ffffff;
    \\      --sidebar-bg: #161b22;
    \\      --sidebar-border: #30363d;
    \\      --toc-link-color: #8b949e;
    \\      --toc-link-hover: #c9d1d9;
    \\      --toc-active-bg: #1f2937;
    \\      --toc-active-border: #3b82f6;
    \\      --code-bg: #161b22;
    \\      --code-border: #30363d;
    \\      --blockquote-border: #30363d;
    \\      --blockquote-bg: #161b22;
    \\      --table-border: #30363d;
    \\      --table-header-bg: #161b22;
    \\      --table-row-alt: #0d1117;
    \\      --hr-color: #30363d;
    \\      --kbd-bg: #161b22;
    \\      --kbd-border: #30363d;
    \\      --btn-bg: #21262d;
    \\      --btn-border: #30363d;
    \\      --btn-color: #c9d1d9;
    \\      --btn-hover-bg: #30363d;
    \\      --btn-active-bg: #3b82f6;
    \\      --btn-active-color: #ffffff;
    \\      --meta-bg: #161b22;
    \\      --source-bg: #161b22;
    \\      --scrollbar-thumb: #30363d;
    \\      --scrollbar-track: #0d1117;
    \\    }}
    \\    * {{ box-sizing: border-box; }}
    \\    html, body {{ margin: 0; padding: 0; }}
    \\    body {{
    \\      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
    \\      background-color: var(--bg-color);
    \\      color: var(--text-color);
    \\      line-height: 1.6;
    \\      transition: background-color 0.3s, color 0.3s;
    \\    }}
    \\    ::-webkit-scrollbar {{ width: 8px; height: 8px; }}
    \\    ::-webkit-scrollbar-track {{ background: var(--scrollbar-track); }}
    \\    ::-webkit-scrollbar-thumb {{ background: var(--scrollbar-thumb); border-radius: 4px; }}
    \\    ::-webkit-scrollbar-thumb:hover {{ background: var(--text-secondary); }}
    \\    .header {{
    \\      background: linear-gradient(135deg, var(--header-gradient-start) 0%, var(--header-gradient-end) 100%);
    \\      color: var(--header-text);
    \\      padding: 0;
    \\      box-shadow: 0 2px 8px rgba(0,0,0,0.15);
    \\      position: sticky;
    \\      top: 0;
    \\      z-index: 100;
    \\    }}
    \\    .header-content {{
    \\      max-width: 1400px;
    \\      margin: 0 auto;
    \\      padding: 16px 24px;
    \\      display: flex;
    \\      align-items: center;
    \\      justify-content: space-between;
    \\      flex-wrap: wrap;
    \\      gap: 12px;
    \\    }}
    \\    .header-left {{ display: flex; align-items: center; gap: 16px; }}
    \\    .header-title {{
    \\      font-size: 1.25rem;
    \\      font-weight: 600;
    \\      display: flex;
    \\      align-items: center;
    \\      gap: 10px;
    \\    }}
    \\    .header-title .icon {{ font-size: 1.4rem; }}
    \\    .back-btn {{
    \\      display: inline-flex;
    \\      align-items: center;
    \\      gap: 6px;
    \\      padding: 8px 16px;
    \\      background: rgba(255,255,255,0.15);
    \\      border: 1px solid rgba(255,255,255,0.25);
    \\      border-radius: 6px;
    \\      color: var(--header-text);
    \\      text-decoration: none;
    \\      font-size: 0.875rem;
    \\      font-weight: 500;
    \\      transition: all 0.2s;
    \\    }}
    \\    .back-btn:hover {{ background: rgba(255,255,255,0.25); transform: translateY(-1px); }}
    \\    .header-right {{ display: flex; align-items: center; gap: 12px; }}
    \\    .view-toggle {{
    \\      display: flex;
    \\      background: rgba(255,255,255,0.1);
    \\      border-radius: 8px;
    \\      padding: 3px;
    \\    }}
    \\    .view-toggle button {{
    \\      padding: 8px 16px;
    \\      border: none;
    \\      background: transparent;
    \\      color: rgba(255,255,255,0.8);
    \\      font-size: 0.875rem;
    \\      font-weight: 500;
    \\      cursor: pointer;
    \\      border-radius: 6px;
    \\      transition: all 0.2s;
    \\      display: flex;
    \\      align-items: center;
    \\      gap: 6px;
    \\    }}
    \\    .view-toggle button:hover {{ color: var(--header-text); }}
    \\    .view-toggle button.active {{
    \\      background: rgba(255,255,255,0.2);
    \\      color: var(--header-text);
    \\    }}
    \\    .theme-toggle {{
    \\      padding: 8px 12px;
    \\      background: rgba(255,255,255,0.1);
    \\      border: 1px solid rgba(255,255,255,0.2);
    \\      border-radius: 6px;
    \\      color: var(--header-text);
    \\      font-size: 0.875rem;
    \\      cursor: pointer;
    \\      transition: all 0.2s;
    \\    }}
    \\    .theme-toggle:hover {{ background: rgba(255,255,255,0.2); }}
    \\    .container {{
    \\      max-width: 1400px;
    \\      margin: 0 auto;
    \\      display: flex;
    \\      min-height: calc(100vh - 64px);
    \\    }}
    \\    .sidebar {{
    \\      width: 280px;
    \\      flex-shrink: 0;
    \\      background: var(--sidebar-bg);
    \\      border-right: 1px solid var(--sidebar-border);
    \\      padding: 20px;
    \\      overflow-y: auto;
    \\      max-height: calc(100vh - 64px);
    \\      position: sticky;
    \\      top: 64px;
    \\    }}
    \\    .sidebar-section {{ margin-bottom: 24px; }}
    \\    .sidebar-title {{
    \\      font-size: 0.75rem;
    \\      font-weight: 600;
    \\      text-transform: uppercase;
    \\      letter-spacing: 0.05em;
    \\      color: var(--text-secondary);
    \\      margin-bottom: 12px;
    \\      padding-bottom: 8px;
    \\      border-bottom: 1px solid var(--sidebar-border);
    \\    }}
    \\    .toc-list {{ list-style: none; padding: 0; margin: 0; }}
    \\    .toc-list li {{ margin: 4px 0; }}
    \\    .toc-list a {{
    \\      display: block;
    \\      padding: 6px 10px;
    \\      color: var(--toc-link-color);
    \\      text-decoration: none;
    \\      font-size: 0.875rem;
    \\      border-radius: 6px;
    \\      border-left: 3px solid transparent;
    \\      transition: all 0.2s;
    \\      white-space: nowrap;
    \\      overflow: hidden;
    \\      text-overflow: ellipsis;
    \\    }}
    \\    .toc-list a:hover {{
    \\      color: var(--toc-link-hover);
    \\      background: var(--hover-bg);
    \\    }}
    \\    .toc-list a.active {{
    \\      color: var(--link-color);
    \\      background: var(--toc-active-bg);
    \\      border-left-color: var(--toc-active-border);
    \\      font-weight: 500;
    \\    }}
    \\    .toc-h1 {{ padding-left: 10px !important; }}
    \\    .toc-h2 {{ padding-left: 22px !important; }}
    \\    .toc-h3 {{ padding-left: 34px !important; }}
    \\    .toc-h4 {{ padding-left: 46px !important; }}
    \\    .toc-h5 {{ padding-left: 58px !important; }}
    \\    .toc-h6 {{ padding-left: 70px !important; }}
    \\    .file-meta {{
    \\      background: var(--meta-bg);
    \\      border-radius: 8px;
    \\      padding: 12px;
    \\      font-size: 0.8125rem;
    \\    }}
    \\    .file-meta-item {{
    \\      display: flex;
    \\      justify-content: space-between;
    \\      padding: 4px 0;
    \\      border-bottom: 1px solid var(--sidebar-border);
    \\    }}
    \\    .file-meta-item:last-child {{ border-bottom: none; }}
    \\    .file-meta-label {{ color: var(--text-secondary); }}
    \\    .file-meta-value {{ font-weight: 500; color: var(--text-color); }}
    \\    .main {{
    \\      flex: 1;
    \\      padding: 32px 40px;
    \\      max-width: 900px;
    \\    }}
    \\    .markdown-body {{
    \\      font-size: 16px;
    \\      line-height: 1.6;
    \\      color: var(--text-color);
    \\    }}
    \\    .markdown-body > *:first-child {{ margin-top: 0 !important; }}
    \\    .markdown-body h1, .markdown-body h2, .markdown-body h3,
    \\    .markdown-body h4, .markdown-body h5, .markdown-body h6 {{
    \\      margin-top: 32px;
    \\      margin-bottom: 16px;
    \\      font-weight: 600;
    \\      line-height: 1.25;
    \\      color: var(--text-color);
    \\      scroll-margin-top: 80px;
    \\    }}
    \\    .markdown-body h1 {{
    \\      font-size: 2em;
    \\      padding-bottom: 0.3em;
    \\      border-bottom: 1px solid var(--hr-color);
    \\    }}
    \\    .markdown-body h2 {{
    \\      font-size: 1.5em;
    \\      padding-bottom: 0.3em;
    \\      border-bottom: 1px solid var(--hr-color);
    \\    }}
    \\    .markdown-body h3 {{ font-size: 1.25em; }}
    \\    .markdown-body h4 {{ font-size: 1em; }}
    \\    .markdown-body h5 {{ font-size: 0.875em; }}
    \\    .markdown-body h6 {{
    \\      font-size: 0.85em;
    \\      color: var(--text-secondary);
    \\    }}
    \\    .markdown-body h1 .anchor, .markdown-body h2 .anchor, .markdown-body h3 .anchor,
    \\    .markdown-body h4 .anchor, .markdown-body h5 .anchor, .markdown-body h6 .anchor {{
    \\      float: left;
    \\      margin-left: -20px;
    \\      padding-right: 4px;
    \\      text-decoration: none;
    \\      opacity: 0;
    \\      transition: opacity 0.2s;
    \\    }}
    \\    .markdown-body h1:hover .anchor, .markdown-body h2:hover .anchor, .markdown-body h3:hover .anchor,
    \\    .markdown-body h4:hover .anchor, .markdown-body h5:hover .anchor, .markdown-body h6:hover .anchor {{
    \\      opacity: 1;
    \\    }}
    \\    .markdown-body p {{ margin-bottom: 16px; }}
    \\    .markdown-body a {{ color: var(--link-color); text-decoration: none; }}
    \\    .markdown-body a:hover {{ text-decoration: underline; }}
    \\    .markdown-body strong {{ font-weight: 600; }}
    \\    .markdown-body em {{ font-style: italic; }}
    \\    .markdown-body ul, .markdown-body ol {{
    \\      margin-bottom: 16px;
    \\      padding-left: 2em;
    \\    }}
    \\    .markdown-body ul {{ list-style-type: disc; }}
    \\    .markdown-body ul ul {{ list-style-type: circle; }}
    \\    .markdown-body ul ul ul {{ list-style-type: square; }}
    \\    .markdown-body ol {{ list-style-type: decimal; }}
    \\    .markdown-body li {{ margin: 0.25em 0; }}
    \\    .markdown-body li > p {{ margin-bottom: 0; }}
    \\    .markdown-body li + li {{ margin-top: 0.25em; }}
    \\    .markdown-body .task-list-item {{
    \\      list-style-type: none;
    \\      margin-left: -1.5em;
    \\    }}
    \\    .markdown-body .task-list-item input[type="checkbox"] {{
    \\      margin-right: 0.5em;
    \\      accent-color: var(--header-gradient-start);
    \\    }}
    \\    .markdown-body code {{
    \\      font-family: ui-monospace, SFMono-Regular, "SF Mono", Consolas, "Liberation Mono", Menlo, monospace;
    \\      font-size: 0.875em;
    \\      padding: 0.2em 0.4em;
    \\      background: var(--code-bg);
    \\      border: 1px solid var(--code-border);
    \\      border-radius: 6px;
    \\      color: var(--text-color);
    \\    }}
    \\    .markdown-body pre {{
    \\      margin-bottom: 16px;
    \\      padding: 16px;
    \\      overflow: auto;
    \\      font-size: 85%;
    \\      line-height: 1.45;
    \\      background: var(--code-bg);
    \\      border: 1px solid var(--code-border);
    \\      border-radius: 8px;
    \\    }}
    \\    .markdown-body pre code {{
    \\      display: block;
    \\      padding: 0;
    \\      margin: 0;
    \\      overflow: visible;
    \\      line-height: inherit;
    \\      word-wrap: normal;
    \\      background: transparent;
    \\      border: 0;
    \\      font-size: 100%;
    \\    }}
    \\    .markdown-body pre .hljs {{
    \\      background: transparent;
    \\      padding: 0;
    \\    }}
    \\    .markdown-body blockquote {{
    \\      margin: 0 0 16px;
    \\      padding: 0 1em;
    \\      color: var(--text-secondary);
    \\      border-left: 0.25em solid var(--blockquote-border);
    \\      background: var(--blockquote-bg);
    \\      border-radius: 0 6px 6px 0;
    \\      padding: 12px 16px;
    \\    }}
    \\    .markdown-body blockquote > :first-child {{ margin-top: 0; }}
    \\    .markdown-body blockquote > :last-child {{ margin-bottom: 0; }}
    \\    .markdown-body table {{
    \\      display: block;
    \\      width: 100%;
    \\      width: max-content;
    \\      max-width: 100%;
    \\      overflow: auto;
    \\      border-spacing: 0;
    \\      border-collapse: collapse;
    \\      margin-bottom: 16px;
    \\    }}
    \\    .markdown-body table th, .markdown-body table td {{
    \\      padding: 8px 12px;
    \\      border: 1px solid var(--table-border);
    \\      text-align: left;
    \\    }}
    \\    .markdown-body table th {{
    \\      font-weight: 600;
    \\      background: var(--table-header-bg);
    \\    }}
    \\    .markdown-body table tr:nth-child(2n) {{ background: var(--table-row-alt); }}
    \\    .markdown-body img {{
    \\      max-width: 100%;
    \\      height: auto;
    \\      box-sizing: border-box;
    \\      background-color: var(--bg-color);
    \\      border-radius: 6px;
    \\      border: 1px solid var(--border-color);
    \\    }}
    \\    .markdown-body hr {{
    \\      height: 0.25em;
    \\      padding: 0;
    \\      margin: 24px 0;
    \\      background-color: var(--hr-color);
    \\      border: 0;
    \\      border-radius: 2px;
    \\    }}
    \\    .markdown-body kbd {{
    \\      display: inline-block;
    \\      padding: 3px 6px;
    \\      font-family: ui-monospace, SFMono-Regular, "SF Mono", Consolas, "Liberation Mono", Menlo, monospace;
    \\      font-size: 0.75em;
    \\      line-height: 1;
    \\      color: var(--text-color);
    \\      vertical-align: middle;
    \\      background: var(--kbd-bg);
    \\      border: 1px solid var(--kbd-border);
    \\      border-radius: 6px;
    \\      box-shadow: inset 0 -1px 0 var(--kbd-border);
    \\    }}
    \\    .source-view {{
    \\      display: none;
    \\      background: var(--source-bg);
    \\      border: 1px solid var(--border-color);
    \\      border-radius: 8px;
    \\      padding: 20px;
    \\      overflow-x: auto;
    \\    }}
    \\    .source-view pre {{
    \\      margin: 0;
    \\      font-family: ui-monospace, SFMono-Regular, "SF Mono", Consolas, "Liberation Mono", Menlo, monospace;
    \\      font-size: 14px;
    \\      line-height: 1.6;
    \\      white-space: pre;
    \\      word-wrap: normal;
    \\    }}
    \\    .source-view pre code {{
    \\      display: block;
    \\      background: transparent;
    \\      border: none;
    \\      padding: 0;
    \\    }}
    \\    .source-view.active {{ display: block; }}
    \\    .markdown-body.hidden {{ display: none; }}
    \\    .sidebar-toggle {{
    \\      display: none;
    \\      position: fixed;
    \\      bottom: 20px;
    \\      right: 20px;
    \\      width: 50px;
    \\      height: 50px;
    \\      border-radius: 50%;
    \\      background: var(--header-gradient-start);
    \\      border: none;
    \\      color: white;
    \\      font-size: 20px;
    \\      cursor: pointer;
    \\      box-shadow: 0 4px 12px rgba(0,0,0,0.3);
    \\      z-index: 200;
    \\      transition: transform 0.2s;
    \\    }}
    \\    .sidebar-toggle:hover {{ transform: scale(1.1); }}
    \\    .toc-empty {{
    \\      color: var(--text-secondary);
    \\      font-size: 0.8125rem;
    \\      font-style: italic;
    \\      padding: 8px 0;
    \\    }}
    \\    @media (max-width: 1024px) {{
    \\      .sidebar {{
    \\        position: fixed;
    \\        left: -300px;
    \\        top: 64px;
    \\        height: calc(100vh - 64px);
    \\        z-index: 99;
    \\        transition: left 0.3s ease;
    \\        box-shadow: 2px 0 8px rgba(0,0,0,0.1);
    \\      }}
    \\      .sidebar.open {{ left: 0; }}
    \\      .main {{
    \\        padding: 24px;
    \\        max-width: 100%;
    \\      }}
    \\      .sidebar-toggle {{ display: flex; align-items: center; justify-content: center; }}
    \\      .overlay {{
    \\        display: none;
    \\        position: fixed;
    \\        top: 64px;
    \\        left: 0;
    \\        right: 0;
    \\        bottom: 0;
    \\        background: rgba(0,0,0,0.5);
    \\        z-index: 98;
    \\      }}
    \\      .overlay.show {{ display: block; }}
    \\    }}
    \\    @media (max-width: 640px) {{
    \\      .header-content {{
    \\        padding: 12px 16px;
    \\      }}
    \\      .header-title {{
    \\        font-size: 1rem;
    \\      }}
    \\      .view-toggle button {{
    \\        padding: 6px 12px;
    \\        font-size: 0.8125rem;
    \\      }}
    \\      .main {{
    \\        padding: 16px;
    \\      }}
    \\      .markdown-body h1 {{ font-size: 1.75em; }}
    \\      .markdown-body h2 {{ font-size: 1.4em; }}
    \\      .markdown-body h3 {{ font-size: 1.2em; }}
    \\    }}
    \\  </style>
    \\</head>
    \\<body>
    \\  <header class="header">
    \\    <div class="header-content">
    \\      <div class="header-left">
    \\        <a href="{1s}" class="back-btn">
    \\          <span>←</span> Back to directory
    \\        </a>
    \\        <div class="header-title">
    \\          <span class="icon">📝</span>
    \\          <span>{2s}</span>
    \\        </div>
    \\      </div>
    \\      <div class="header-right">
    \\        <div class="view-toggle">
    \\          <button id="viewRendered" class="active" onclick="switchView('rendered')">
    \\            <span>👁</span> Rendered
    \\          </button>
    \\          <button id="viewSource" onclick="switchView('source')">
    \\            <span>📄</span> Source
    \\          </button>
    \\        </div>
    \\        <button class="theme-toggle" onclick="toggleTheme()" id="themeToggle">🌙 Dark</button>
    \\      </div>
    \\    </div>
    \\  </header>
    \\  <div class="overlay" id="overlay" onclick="toggleSidebar()"></div>
    \\  <div class="container">
    \\    <aside class="sidebar" id="sidebar">
    \\      <div class="sidebar-section">
    \\        <div class="sidebar-title">Table of Contents</div>
    \\        <nav id="toc"><div class="toc-empty">No headings found</div></nav>
    \\      </div>
    \\      <div class="sidebar-section">
    \\        <div class="sidebar-title">File Info</div>
    \\        <div class="file-meta">
    \\          <div class="file-meta-item">
    \\            <span class="file-meta-label">Size</span>
    \\            <span class="file-meta-value">{3s}</span>
    \\          </div>
    \\          <div class="file-meta-item">
    \\            <span class="file-meta-label">Type</span>
    \\            <span class="file-meta-value">{4s}</span>
    \\          </div>
    \\        </div>
    \\      </div>
    \\    </aside>
    \\    <main class="main">
    \\      <div id="renderedView" class="markdown-body"></div>
    \\      <div id="sourceView" class="source-view"><pre><code>{6s}</code></pre></div>
    \\    </main>
    \\  </div>
    \\  <button class="sidebar-toggle" onclick="toggleSidebar()" title="Toggle Table of Contents">📑</button>
    \\  <script>
    \\    (function() {{
    \\      // Raw markdown content from server
    \\      const rawMarkdown = `{5s}`;
    \\      
    \\      // Configure marked.js
    \\      marked.setOptions({{
    \\        gfm: true,
    \\        breaks: false,
    \\        pedantic: false,
    \\        smartLists: true,
    \\        smartypants: true,
    \\        xhtml: false,
    \\        headerIds: true,
    \\        headerPrefix: '',
    \\        mangle: false,
    \\        sanitize: false,
    \\        sanitizer: null,
    \\        renderer: new marked.Renderer(),
    \\        highlight: function(code, lang) {{
    \\          if (lang && hljs.getLanguage(lang)) {{
    \\            try {{
    \\              return hljs.highlight(code, {{ language: lang }}).value;
    \\            }} catch (e) {{}}
    \\          }}
    \\          return hljs.highlightAuto(code).value;
    \\        }}
    \\      }});
    \\      
    \\      // Render markdown
    \\      const renderedView = document.getElementById('renderedView');
    \\      renderedView.innerHTML = marked.parse(rawMarkdown);
    \\      
    \\      // Generate table of contents
    \\      function generateTOC() {{
    \\        const headings = renderedView.querySelectorAll('h1, h2, h3, h4, h5, h6');
    \\        const toc = document.getElementById('toc');
    \\        if (headings.length === 0) {{
    \\          toc.innerHTML = '<div class="toc-empty">No headings found</div>';
    \\          return;
    \\        }}
    \\        const ul = document.createElement('ul');
    \\        ul.className = 'toc-list';
    \\        headings.forEach((heading, index) => {{
    \\          const level = parseInt(heading.tagName.charAt(1));
    \\          const text = heading.textContent;
    \\          let id = heading.id;
    \\          if (!id) {{
    \\            id = 'heading-' + index;
    \\            heading.id = id;
    \\          }}
    \\          const li = document.createElement('li');
    \\          const a = document.createElement('a');
    \\          a.href = '#' + id;
    \\          a.textContent = text;
    \\          a.className = 'toc-h' + level;
    \\          a.dataset.target = id;
    \\          a.addEventListener('click', function(e) {{
    \\            e.preventDefault();
    \\            document.getElementById(id).scrollIntoView({{ behavior: 'smooth' }});
    \\            history.pushState(null, null, '#' + id);
    \\          }});
    \\          li.appendChild(a);
    \\          ul.appendChild(li);
    \\        }});
    \\        toc.innerHTML = '';
    \\        toc.appendChild(ul);
    \\      }}
    \\      
    \\      // Update active TOC item on scroll
    \\      function updateActiveTOC() {{
    \\        const headings = renderedView.querySelectorAll('h1, h2, h3, h4, h5, h6');
    \\        const tocLinks = document.querySelectorAll('.toc-list a');
    \\        let current = '';
    \\        const scrollPos = window.scrollY + 100;
    \\        headings.forEach(heading => {{
    \\          if (heading.offsetTop <= scrollPos) {{
    \\            current = heading.id;
    \\          }}
    \\        }});
    \\        tocLinks.forEach(link => {{
    \\          link.classList.remove('active');
    \\          if (link.dataset.target === current) {{
    \\            link.classList.add('active');
    \\          }}
    \\        }});
    \\      }}
    \\      
    \\      // Initialize
    \\      generateTOC();
    \\      updateActiveTOC();
    \\      window.addEventListener('scroll', updateActiveTOC);
    \\      
    \\      // Apply syntax highlighting
    \\      if (typeof hljs !== 'undefined') {{
    \\        hljs.highlightAll();
    \\      }}
    \\      
    \\      // View switching
    \\      window.switchView = function(view) {{
    \\        const renderedEl = document.getElementById('renderedView');
    \\        const sourceEl = document.getElementById('sourceView');
    \\        const renderedBtn = document.getElementById('viewRendered');
    \\        const sourceBtn = document.getElementById('viewSource');
    \\        if (view === 'rendered') {{
    \\          renderedEl.classList.remove('hidden');
    \\          sourceEl.classList.remove('active');
    \\          renderedBtn.classList.add('active');
    \\          sourceBtn.classList.remove('active');
    \\          localStorage.setItem('markdown-view', 'rendered');
    \\        }} else {{
    \\          renderedEl.classList.add('hidden');
    \\          sourceEl.classList.add('active');
    \\          renderedBtn.classList.remove('active');
    \\          sourceBtn.classList.add('active');
    \\          localStorage.setItem('markdown-view', 'source');
    \\        }}
    \\      }};
    \\      
    \\      // Restore view preference
    \\      const savedView = localStorage.getItem('markdown-view');
    \\      if (savedView === 'source') {{
    \\        switchView('source');
    \\      }}
    \\      
    \\      // Theme handling
    \\      window.toggleTheme = function() {{
    \\        const isDark = document.body.classList.toggle('dark-mode');
    \\        localStorage.setItem('theme', isDark ? 'dark' : 'light');
    \\        updateThemeUI();
    \\      }};
    \\      
    \\      function updateThemeUI() {{
    \\        const isDark = document.body.classList.contains('dark-mode');
    \\        const btn = document.getElementById('themeToggle');
    \\        if (btn) {{
    \\          btn.textContent = isDark ? '☀️ Light' : '🌙 Dark';
    \\        }}
    \\        // Update highlight.js theme
    \\        const hljsTheme = document.getElementById('hljs-theme');
    \\        if (hljsTheme) {{
    \\          hljsTheme.href = isDark
    \\            ? 'https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css'
    \\            : 'https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css';
    \\        }}
    \\      }}
    \\      
    \\      function initTheme() {{
    \\        const savedTheme = localStorage.getItem('theme');
    \\        if (savedTheme === 'dark') {{
    \\          document.body.classList.add('dark-mode');
    \\        }} else if (savedTheme === 'light') {{
    \\          document.body.classList.remove('dark-mode');
    \\        }} else if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {{
    \\          document.body.classList.add('dark-mode');
    \\        }}
    \\        updateThemeUI();
    \\      }}
    \\      
    \\      // Sidebar toggle for mobile
    \\      window.toggleSidebar = function() {{
    \\        const sidebar = document.getElementById('sidebar');
    \\        const overlay = document.getElementById('overlay');
    \\        sidebar.classList.toggle('open');
    \\        overlay.classList.toggle('show');
    \\      }};
    \\      
    \\      // Initialize theme
    \\      initTheme();
    \\    }})();
    \\  </script>
    \\</body>
    \\</html>
;

/// Format a file size for display (same as directory.zig formatSize)
fn formatSize(buf: []u8, size: u64) []const u8 {
    if (size < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{size}) catch "0 B";
    } else if (size < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{@as(f64, @floatFromInt(size)) / 1024}) catch "0 KB";
    } else if (size < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(size)) / (1024 * 1024)}) catch "0 MB";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1} GB", .{@as(f64, @floatFromInt(size)) / (1024 * 1024 * 1024)}) catch "0 GB";
    }
}

/// Escape a string for safe embedding in JavaScript string literal
fn escapeForJs(allocator: std.mem.Allocator, input: []const u8) error{OutOfMemory}![]u8 {
    // Calculate required size
    var escape_count: usize = 0;
    for (input) |c| {
        switch (c) {
            '\\', '"', '\n', '\r', '\t', '`', '$' => escape_count += 1,
            else => {},
        }
    }

    const result = try allocator.alloc(u8, input.len + escape_count);
    var i: usize = 0;
    for (input) |c| {
        switch (c) {
            '\\' => {
                result[i] = '\\';
                result[i + 1] = '\\';
                i += 2;
            },
            '"' => {
                result[i] = '\\';
                result[i + 1] = '"';
                i += 2;
            },
            '\n' => {
                result[i] = '\\';
                result[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                result[i] = '\\';
                result[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                result[i] = '\\';
                result[i + 1] = 't';
                i += 2;
            },
            '`' => {
                result[i] = '\\';
                result[i + 1] = '`';
                i += 2;
            },
            '$' => {
                result[i] = '\\';
                result[i + 1] = '$';
                i += 2;
            },
            else => {
                result[i] = c;
                i += 1;
            },
        }
    }

    return result;
}

/// Escape a string for safe embedding in HTML
fn escapeForHtml(allocator: std.mem.Allocator, input: []const u8) error{OutOfMemory}![]u8 {
    // Calculate required size
    var escape_count: usize = 0;
    for (input) |c| {
        switch (c) {
            '&' => escape_count += 4, // &amp; = 5 bytes, net +4
            '<' => escape_count += 3, // &lt; = 4 bytes, net +3
            '>' => escape_count += 3, // &gt; = 4 bytes, net +3
            '"' => escape_count += 5, // &quot; = 6 bytes, net +5
            '\'' => escape_count += 4, // &#x27; = 5 bytes, net +4
            else => {},
        }
    }

    const result = try allocator.alloc(u8, input.len + escape_count);
    var i: usize = 0;
    for (input) |c| {
        switch (c) {
            '&' => {
                @memcpy(result[i .. i + 5], "&amp;");
                i += 5;
            },
            '<' => {
                @memcpy(result[i .. i + 4], "&lt;");
                i += 4;
            },
            '>' => {
                @memcpy(result[i .. i + 4], "&gt;");
                i += 4;
            },
            '"' => {
                @memcpy(result[i .. i + 6], "&quot;");
                i += 6;
            },
            '\'' => {
                @memcpy(result[i .. i + 5], "&#x27;");
                i += 5;
            },
            else => {
                result[i] = c;
                i += 1;
            },
        }
    }

    return result;
}

/// Send a Markdown file as an HTML preview page
pub fn renderMarkdownPreview(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file_path: []const u8,
    dir_path: []const u8,
    file_content: []const u8,
    file_size: u64,
) !void {
    // Create stream writer
    var write_buf: [65536]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);

    // Send HTTP response headers
    try stream_writer.interface.writeAll("HTTP/1.1 200 OK\r\n");
    try stream_writer.interface.writeAll("Content-Type: text/html; charset=utf-8\r\n");
    try stream_writer.interface.writeAll("\r\n");

    // Get filename from path
    const filename = std.fs.path.basename(file_path);

    // Build parent directory URL - ensure it starts with /
    const parent_dir = blk: {
        if (std.mem.eql(u8, dir_path, ".") or dir_path.len == 0) {
            break :blk "/";
        }
        // Ensure the path starts with /
        if (std.mem.startsWith(u8, dir_path, "/")) {
            break :blk dir_path;
        } else {
            const with_slash = try allocator.alloc(u8, dir_path.len + 1);
            with_slash[0] = '/';
            @memcpy(with_slash[1..], dir_path);
            break :blk with_slash;
        }
    };
    defer if (parent_dir.len > 1 and !std.mem.startsWith(u8, dir_path, "/")) allocator.free(parent_dir);

    // Format file size
    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, file_size);

    // Escape markdown content for JavaScript (for rendering)
    const escaped_content = try escapeForJs(allocator, file_content);
    defer allocator.free(escaped_content);

    // Escape markdown content for HTML (for source view)
    const html_escaped_content = try escapeForHtml(allocator, file_content);
    defer allocator.free(html_escaped_content);

    // Escape filename for HTML
    var html_filename_buf: [1024]u8 = undefined;
    var html_filename_len: usize = 0;
    for (filename) |c| {
        switch (c) {
            '&' => {
                if (html_filename_len + 5 < html_filename_buf.len) {
                    @memcpy(html_filename_buf[html_filename_len .. html_filename_len + 5], "&amp;");
                    html_filename_len += 5;
                }
            },
            '<' => {
                if (html_filename_len + 4 < html_filename_buf.len) {
                    @memcpy(html_filename_buf[html_filename_len .. html_filename_len + 4], "&lt;");
                    html_filename_len += 4;
                }
            },
            '>' => {
                if (html_filename_len + 4 < html_filename_buf.len) {
                    @memcpy(html_filename_buf[html_filename_len .. html_filename_len + 4], "&gt;");
                    html_filename_len += 4;
                }
            },
            '"' => {
                if (html_filename_len + 6 < html_filename_buf.len) {
                    @memcpy(html_filename_buf[html_filename_len .. html_filename_len + 6], "&quot;");
                    html_filename_len += 6;
                }
            },
            else => {
                if (html_filename_len < html_filename_buf.len) {
                    html_filename_buf[html_filename_len] = c;
                    html_filename_len += 1;
                }
            },
        }
    }
    const html_filename = html_filename_buf[0..html_filename_len];

    // Write the HTML response
    try stream_writer.interface.print(markdown_preview_template, .{
        html_filename, // {0s} - page title
        parent_dir, // {1s} - parent directory URL
        html_filename, // {2s} - filename
        size_str, // {3s} - file size
        "text/markdown", // {4s} - mime type
        escaped_content, // {5s} - raw markdown content (JS-escaped for rendering)
        html_escaped_content, // {6s} - raw markdown content (HTML-escaped for source view)
    });

    try stream_writer.interface.flush();
}
