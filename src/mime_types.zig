const std = @import("std");

pub fn getMimeType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);

    // Convert extension to lowercase for comparison
    var ext_lower: [16]u8 = undefined;
    if (extension.len > ext_lower.len) return "application/octet-stream";
    
    for (extension, 0..) |c, i| {
        ext_lower[i] = std.ascii.toLower(c);
    }
    const ext = ext_lower[0..extension.len];

    // Text types
    if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";

    // Image types
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".webp")) return "image/webp";
    if (std.mem.eql(u8, ext, ".avif")) return "image/avif";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";

    // Video types
    if (std.mem.eql(u8, ext, ".mp4")) return "video/mp4";
    if (std.mem.eql(u8, ext, ".webm")) return "video/webm";
    if (std.mem.eql(u8, ext, ".mkv")) return "video/x-matroska";

    // Audio types
    if (std.mem.eql(u8, ext, ".mp3")) return "audio/mpeg";
    if (std.mem.eql(u8, ext, ".wav")) return "audio/wav";
    if (std.mem.eql(u8, ext, ".ogg")) return "audio/ogg";

    // Document types
    if (std.mem.eql(u8, ext, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, ext, ".zip")) return "application/zip";

    // Code types
    if (std.mem.eql(u8, ext, ".py")) return "text/x-python; charset=utf-8";
    if (std.mem.eql(u8, ext, ".rb")) return "text/x-ruby; charset=utf-8";
    if (std.mem.eql(u8, ext, ".sh")) return "application/x-sh; charset=utf-8";

    // Markup types
    if (std.mem.eql(u8, ext, ".md")) return "text/markdown; charset=utf-8";
    if (std.mem.eql(u8, ext, ".org")) return "text/org; charset=utf-8";

    // Data types
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return "application/yaml";
    if (std.mem.eql(u8, ext, ".toml")) return "application/toml";

    return "application/octet-stream";
}

pub fn isTextFile(mime_type: []const u8) bool {
    return std.mem.startsWith(u8, mime_type, "text/") or
        std.mem.eql(u8, mime_type, "application/javascript");
}
