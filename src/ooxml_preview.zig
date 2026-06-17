const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const nanoxml = @import("nanoxml");
const dom = nanoxml.dom;

// ── Image extraction infrastructure ──────────────────────────────────────

const ImageInfo = struct {
    name: []const u8,
    content_type: []const u8,
    base64_data: []const u8,
};

const MAX_IMAGES = 10;
const MAX_IMAGE_RAW_SIZE: usize = 2 * 1024 * 1024; // 2MB per image
const MAX_TOTAL_BASE64: usize = 10 * 1024 * 1024; // 10MB total

fn isImageContentType(ct: []const u8) bool {
    return std.mem.startsWith(u8, ct, "image/");
}

fn isMediaPath(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "media/") != null;
}

fn extractMediaImages(pkg: *nanoxml.opc.Package, allocator: std.mem.Allocator) !std.ArrayList(ImageInfo) {
    var images: std.ArrayList(ImageInfo) = .empty;
    errdefer {
        for (images.items) |img| allocator.free(img.base64_data);
        images.deinit(allocator);
    }
    try images.ensureTotalCapacity(allocator, 4);
    var total_base64: usize = 0;

    const part_names = pkg.partNames(allocator) catch return images;
    defer allocator.free(part_names);

    for (part_names) |name| {
        if (images.items.len >= MAX_IMAGES) break;
        if (!isMediaPath(name)) continue;

        const ct = pkg.contentTypeOf(name) orelse continue;
        if (!isImageContentType(ct)) continue;

        const bytes = pkg.getPart(name) catch continue;
        if (bytes.len == 0 or bytes.len > MAX_IMAGE_RAW_SIZE) continue;

        const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
        if (total_base64 + encoded_len > MAX_TOTAL_BASE64) break;
        total_base64 += encoded_len;

        const encoded = allocator.alloc(u8, encoded_len) catch continue;
        _ = std.base64.standard.Encoder.encode(encoded, bytes);

        images.append(allocator, .{
            .name = name,
            .content_type = ct,
            .base64_data = encoded,
        }) catch {
            allocator.free(encoded);
            break;
        };
    }

    return images;
}

fn buildImageGalleryHtml(allocator: std.mem.Allocator, images: *const std.ArrayList(ImageInfo)) ![]const u8 {
    if (images.items.len == 0) return "";

    var html: std.ArrayList(u8) = .empty;
    errdefer html.deinit(allocator);
    try html.ensureTotalCapacity(allocator, 4096);

    html.appendSlice(allocator,
        \\<div class="gallery-section">
        \\  <div class="gallery-header" onclick="toggleGallery()">
        \\    <span class="gallery-toggle" id="galleryToggle">&#x25B6;</span>
        \\    <span class="gallery-title">&#x1F5BC; Embedded Images (</span>
    ) catch return "";

    const count_str = std.fmt.allocPrint(allocator, "{d}", .{images.items.len}) catch "0";
    defer if (count_str.len > 1) allocator.free(count_str);
    html.appendSlice(allocator, count_str) catch return "";
    html.appendSlice(allocator,
        \\)</span>
        \\  </div>
        \\  <div class="gallery-grid" id="galleryGrid">
    ) catch return "";

    for (images.items, 0..) |img, i| {
        const img_html = std.fmt.allocPrint(allocator,
            \\<div class="gallery-item" onclick="openLightboxIdx({d})">
            \\  <img src="data:{s};base64,{s}" alt="{s}" loading="lazy"/>
            \\  <div class="gallery-label">{s}</div>
            \\</div>
        , .{ i, img.content_type, img.base64_data, img.name, std.fs.path.basename(img.name) }) catch continue;
        defer allocator.free(img_html);
        html.appendSlice(allocator, img_html) catch break;
    }

    html.appendSlice(allocator,
        \\  </div>
        \\</div>
        \\<div class="lightbox" id="lightbox" onclick="closeLightbox(event)">
        \\  <img id="lightboxImg" src="" alt=""/>
        \\</div>
    ) catch return "";

    return html.toOwnedSlice(allocator) catch "";
}

pub // ── Inline content extraction for mixed text+image rendering ───────────

const InlineSegment = union(enum) {
    text: []const u8,
    image: InlineImage,
};

const InlineImage = struct {
    content_type: []const u8,
    base64_data: []const u8,
};

const ParagraphContent = struct {
    segments: []const InlineSegment,
};

/// Extract DOCX content with inline images at their actual positions.
/// Returns paragraphs with mixed text and image segments.
fn extractDocxWithImages(
    pkg: *nanoxml.opc.Package,
    allocator: std.mem.Allocator,
    main_part: []const u8,
) !std.ArrayList(ParagraphContent) {
    var paragraphs: std.ArrayList(ParagraphContent) = .empty;
    errdefer {
        for (paragraphs.items) |para| {
            for (para.segments) |seg| {
                switch (seg) {
                    .text => |t| allocator.free(t),
                    .image => |img| allocator.free(img.base64_data),
                }
            }
            allocator.free(para.segments);
        }
        paragraphs.deinit(allocator);
    }
    try paragraphs.ensureTotalCapacity(allocator, 32);

    // Get relationships for resolving image references
    const rels = try pkg.relationships(main_part);

    // Get document XML
    const doc_bytes = try pkg.getPart(main_part);
    const arena = pkg.arena.allocator();
    const root = try dom.parse(arena, doc_bytes);

    // Build relationship ID to image data map
    var image_map = std.StringHashMap(InlineImage).init(allocator);
    defer {
        var it = image_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.base64_data);
        }
        image_map.deinit();
    }

    // Pre-resolve all image relationships
    var total_base64: usize = 0;
    for (rels) |rel| {
        if (!std.mem.eql(u8, rel.type, nanoxml.opc.RelType.image)) continue;
        if (image_map.count() >= MAX_IMAGES) break;

        const media_path = pkg.resolveTarget(main_part, rel) catch continue;
        const ct = pkg.contentTypeOf(media_path) orelse continue;
        if (!isImageContentType(ct)) continue;

        const bytes = pkg.getPart(media_path) catch continue;
        if (bytes.len == 0 or bytes.len > MAX_IMAGE_RAW_SIZE) continue;

        const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
        if (total_base64 + encoded_len > MAX_TOTAL_BASE64) break;
        total_base64 += encoded_len;

        const encoded = allocator.alloc(u8, encoded_len) catch continue;
        _ = std.base64.standard.Encoder.encode(encoded, bytes);

        try image_map.put(rel.id, .{
            .content_type = ct,
            .base64_data = encoded,
        });
    }

    // Find all paragraphs (w:p) in the document body
    var para_it = root.descendants(allocator, "p");
    defer para_it.deinit();

    while (try para_it.next()) |para| {
        var segments: std.ArrayList(InlineSegment) = .empty;
        errdefer {
            for (segments.items) |seg| {
                switch (seg) {
                    .text => |t| allocator.free(t),
                    .image => |img| allocator.free(img.base64_data),
                }
            }
            segments.deinit(allocator);
        }
        try segments.ensureTotalCapacity(allocator, 4);

        // Iterate through runs (w:r) in this paragraph
        var run_it = para.elements(null);

        while (run_it.next()) |child| {
            const child_local = child.localName();

            // Text run: w:r > w:t
            if (std.mem.eql(u8, child_local, "r")) {
                // Check for drawing (image) first
                if (child.child("drawing")) |drawing| {
                    // Look for blip element with r:embed attribute
                    if (findBlipRelId(drawing)) |rel_id| {
                        if (image_map.get(rel_id)) |img| {
                            const img_copy = allocator.alloc(u8, img.base64_data.len) catch continue;
                            @memcpy(img_copy, img.base64_data);
                            const ct_copy = allocator.dupe(u8, img.content_type) catch {
                                allocator.free(img_copy);
                                continue;
                            };
                            // Store content_type in the image data as "type;base64_data"
                            // For simplicity, we'll encode it differently
                            allocator.free(ct_copy);
                            try segments.append(allocator, .{
                                .image = .{
                                    .content_type = img.content_type,
                                    .base64_data = img_copy,
                                },
                            });
                        }
                    }
                }

                // Extract text from w:t elements
                var text_acc: std.ArrayList(u8) = .empty;
                var has_text = false;
                var t_it = child.descendants(allocator, "t");
                defer t_it.deinit();
                while (try t_it.next()) |t_elem| {
                    const text_content = t_elem.innerText(allocator) catch continue;
                    defer allocator.free(text_content);
                    if (text_content.len > 0) {
                        try text_acc.appendSlice(allocator, text_content);
                        has_text = true;
                    }
                }

                if (has_text and text_acc.items.len > 0) {
                    const text_owned = try text_acc.toOwnedSlice(allocator);
                    try segments.append(allocator, .{ .text = text_owned });
                } else {
                    text_acc.deinit(allocator);
                }
            }
            // Paragraph properties: w:pPr — skip
            else if (std.mem.eql(u8, child_local, "pPr")) {
                continue;
            }
        }

        // Add paragraph separator (newline) as final text segment
        try segments.append(allocator, .{ .text = try allocator.dupe(u8, "\n") });

        try paragraphs.append(allocator, .{
            .segments = try segments.toOwnedSlice(allocator),
        });
    }

    return paragraphs;
}

/// Find r:embed attribute in a drawing element by traversing to blip
fn findBlipRelId(drawing: *dom.Element) ?[]const u8 {
    // Traverse: drawing > inline/graphicFrame > graphic > graphicData > pic > blipFill > blip
    // Also handle: drawing > anchor > ... (same path)
    // Use recursive search for blip element
    return findBlipRelIdRecursive(drawing);
}

fn findBlipRelIdRecursive(el: *dom.Element) ?[]const u8 {
    // Check if this is a blip element with r:embed
    const local = el.localName();
    if (std.mem.eql(u8, local, "blip")) {
        // Try r:embed first, then embed (without prefix)
        if (el.attr("r:embed")) |rid| return rid;
        if (el.attr("embed")) |rid| return rid;
    }

    // Recurse into children
    for (el.children.items) |child_node| {
        switch (child_node) {
            .element => |child_el| {
                if (findBlipRelIdRecursive(child_el)) |rid| return rid;
            },
            else => {},
        }
    }
    return null;
}

/// Build HTML content from inline segments (mixed text + images)
fn buildInlineContentHtml(allocator: std.mem.Allocator, paragraphs: *const std.ArrayList(ParagraphContent)) ![]const u8 {
    var html: std.ArrayList(u8) = .empty;
    errdefer html.deinit(allocator);
    try html.ensureTotalCapacity(allocator, 8192);

    for (paragraphs.items) |para| {
        for (para.segments) |seg| {
            switch (seg) {
                .text => |t| {
                    if (std.mem.eql(u8, t, "\n")) {
                        html.appendSlice(allocator, "<br/>") catch continue;
                    } else {
                        const escaped = htmlEscape(allocator, t) catch t;
                        html.appendSlice(allocator, escaped) catch {};
                        if (escaped.ptr != t.ptr) allocator.free(escaped);
                    }
                },
                .image => |img| {
                    const img_tag = std.fmt.allocPrint(allocator,
                        \\<img class="inline-img" src="data:{s};base64,{s}" loading="lazy" onclick="openLightbox(this)"/>
                    , .{ img.content_type, img.base64_data }) catch continue;
                    defer allocator.free(img_tag);
                    html.appendSlice(allocator, img_tag) catch {};
                },
            }
        }
    }

    return html.toOwnedSlice(allocator) catch "";
}

// ── PPTX inline image extraction ───────────────────────────────────────

const SlideContent = struct {
    text_segments: []const []const u8,
    images: []const InlineImage,
};

/// Extract PPTX slide content with inline images
fn extractPptxSlideWithImages(
    pkg: *nanoxml.opc.Package,
    allocator: std.mem.Allocator,
    slide_part: []const u8,
) !SlideContent {
    // Get relationships for resolving image references
    const rels = try pkg.relationships(slide_part);

    // Get slide XML
    const slide_bytes = try pkg.getPart(slide_part);
    const arena = pkg.arena.allocator();
    const root = try dom.parse(arena, slide_bytes);

    // Build relationship ID to image data map
    var image_map = std.StringHashMap(InlineImage).init(allocator);
    defer {
        var it = image_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.base64_data);
        }
        image_map.deinit();
    }

    // Pre-resolve all image relationships
    var total_base64: usize = 0;
    for (rels) |rel| {
        if (!std.mem.eql(u8, rel.type, nanoxml.opc.RelType.image)) continue;
        if (image_map.count() >= MAX_IMAGES) break;

        const media_path = pkg.resolveTarget(slide_part, rel) catch continue;
        const ct = pkg.contentTypeOf(media_path) orelse continue;
        if (!isImageContentType(ct)) continue;

        const bytes = pkg.getPart(media_path) catch continue;
        if (bytes.len == 0 or bytes.len > MAX_IMAGE_RAW_SIZE) continue;

        const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
        if (total_base64 + encoded_len > MAX_TOTAL_BASE64) break;
        total_base64 += encoded_len;

        const encoded = allocator.alloc(u8, encoded_len) catch continue;
        _ = std.base64.standard.Encoder.encode(encoded, bytes);

        try image_map.put(rel.id, .{
            .content_type = ct,
            .base64_data = encoded,
        });
    }

    // Collect images from the map
    var images: std.ArrayList(InlineImage) = .empty;
    errdefer {
        for (images.items) |img| allocator.free(img.base64_data);
        images.deinit(allocator);
    }
    try images.ensureTotalCapacity(allocator, image_map.count());

    var img_it = image_map.iterator();
    while (img_it.next()) |entry| {
        try images.append(allocator, entry.value_ptr.*);
    }

    // Extract text using existing method (re-parse for text)
    var text_parts: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (text_parts.items) |t| allocator.free(t);
        text_parts.deinit(allocator);
    }

    // Find all shape trees and extract text
    var sp_it = root.descendants(allocator, "sp");
    defer sp_it.deinit();

    while (try sp_it.next()) |sp| {
        var text_acc: std.ArrayList(u8) = .empty;
        var has_text = false;
        var t_it = sp.descendants(allocator, "t");
        defer t_it.deinit();
        while (try t_it.next()) |t_elem| {
            const text_content = t_elem.innerText(allocator) catch continue;
            defer allocator.free(text_content);
            if (text_content.len > 0) {
                try text_acc.appendSlice(allocator, text_content);
                has_text = true;
            }
        }
        if (has_text and text_acc.items.len > 0) {
            try text_parts.append(allocator, try text_acc.toOwnedSlice(allocator));
        } else {
            text_acc.deinit(allocator);
        }
    }

    return .{
        .text_segments = try text_parts.toOwnedSlice(allocator),
        .images = try images.toOwnedSlice(allocator),
    };
}

/// Build slide HTML with inline images
fn buildSlideContentHtml(allocator: std.mem.Allocator, slide: *const SlideContent) ![]const u8 {
    var html: std.ArrayList(u8) = .empty;
    errdefer html.deinit(allocator);
    try html.ensureTotalCapacity(allocator, 4096);

    // Add text segments
    for (slide.text_segments, 0..) |text, i| {
        if (i > 0) html.appendSlice(allocator, "<br/>") catch {};
        const escaped = htmlEscape(allocator, text) catch text;
        html.appendSlice(allocator, escaped) catch {};
        if (escaped.ptr != text.ptr) allocator.free(escaped);
    }

    // Add images inline
    if (slide.images.len > 0) {
        html.appendSlice(allocator, "<div class=\"slide-images\">") catch {};
        for (slide.images) |img| {
            const img_tag = std.fmt.allocPrint(allocator,
                "<img class=\"slide-img\" src=\"data:{s};base64,{s}\" loading=\"lazy\" onclick=\"openLightbox(this)\"/>"
            , .{ img.content_type, img.base64_data }) catch continue;
            defer allocator.free(img_tag);
            html.appendSlice(allocator, img_tag) catch {};
        }
        html.appendSlice(allocator, "</div>") catch {};
    }

    return html.toOwnedSlice(allocator) catch "";
}

pub fn isOfficeFile(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "application/vnd.openxmlformats-officedocument.wordprocessingml.document") or
        std.mem.eql(u8, mime_type, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") or
        std.mem.eql(u8, mime_type, "application/vnd.ms-excel.sheet.macroEnabled.12") or
        std.mem.eql(u8, mime_type, "application/vnd.openxmlformats-officedocument.presentationml.presentation");
}

pub fn renderOfficePreview(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file: Io.File,
    mime_type: []const u8,
    file_path: []const u8,
    dir_path: []const u8,
    file_size: u64,
) !void {
    const file_bytes = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(file_bytes);

    var pos: usize = 0;
    while (pos < file_size) {
        const n = file.readPositionalAll(io, file_bytes[pos..], pos) catch break;
        if (n == 0) break;
        pos += n;
    }

    if (std.mem.eql(u8, mime_type, "application/vnd.openxmlformats-officedocument.wordprocessingml.document")) {
        try renderDocxPreview(io, allocator, stream, file_bytes[0..pos], file_path, dir_path, file_size);
    } else if (std.mem.eql(u8, mime_type, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") or
        std.mem.eql(u8, mime_type, "application/vnd.ms-excel.sheet.macroEnabled.12"))
    {
        try renderXlsxPreview(io, allocator, stream, file_bytes[0..pos], file_path, dir_path, file_size);
    } else if (std.mem.eql(u8, mime_type, "application/vnd.openxmlformats-officedocument.presentationml.presentation")) {
        try renderPptxPreview(io, allocator, stream, file_bytes[0..pos], file_path, dir_path, file_size);
    } else {
        return error.UnsupportedFormat;
    }
}

fn renderDocxPreview(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file_bytes: []const u8,
    file_path: []const u8,
    dir_path: []const u8,
    file_size: u64,
) !void {
    var pkg = nanoxml.opc.Package.open(allocator, file_bytes) catch {
        try renderFallback(io, allocator, stream, file_path, dir_path, file_size, "DOCX", "Failed to parse Office document");
        return;
    };
    defer pkg.deinit();

    var wd = nanoxml.ooxml.WordDocument.open(&pkg) catch {
        try renderFallback(io, allocator, stream, file_path, dir_path, file_size, "DOCX", "Not a valid Word document");
        return;
    };

    // Extract inline content with images at their actual positions
    var inline_content = extractDocxWithImages(&pkg, allocator, wd.main_part) catch {
        try renderFallback(io, allocator, stream, file_path, dir_path, file_size, "DOCX", "Failed to extract content");
        return;
    };
    defer {
        for (inline_content.items) |para| {
            for (para.segments) |seg| {
                switch (seg) {
                    .text => |t| allocator.free(t),
                    .image => |img| allocator.free(img.base64_data),
                }
            }
            allocator.free(para.segments);
        }
        inline_content.deinit(allocator);
    }

    const escaped = try buildInlineContentHtml(allocator, &inline_content);
    defer allocator.free(escaped);

    // Also extract remaining images for gallery fallback
    var images = extractMediaImages(&pkg, allocator) catch std.ArrayList(ImageInfo){};
    defer {
        for (images.items) |img| allocator.free(img.base64_data);
        images.deinit(allocator);
    }
    const gallery_html = buildImageGalleryHtml(allocator, &images) catch "";
    defer if (gallery_html.len > 0) allocator.free(gallery_html);

    const filename = std.fs.path.basename(file_path);
    const parent_dir = buildParentDir(allocator, dir_path);
    defer if (parent_dir.len > 1 and !std.mem.startsWith(u8, dir_path, "/")) allocator.free(parent_dir);

    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, file_size);

    var write_buf: [65536]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n");

    const image_count_str = std.fmt.allocPrint(allocator, "{d}", .{images.items.len}) catch "0";
    defer if (image_count_str.len > 1) allocator.free(image_count_str);

    const html = try std.fmt.allocPrint(allocator, docx_html_template, .{
        filename, parent_dir, filename, size_str, image_count_str, escaped, gallery_html,
    });
    defer allocator.free(html);

    try writer.interface.writeAll(html);
    try writer.interface.flush();
}

fn renderXlsxPreview(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file_bytes: []const u8,
    file_path: []const u8,
    dir_path: []const u8,
    file_size: u64,
) !void {
    var pkg = nanoxml.opc.Package.open(allocator, file_bytes) catch {
        try renderFallback(io, allocator, stream, file_path, dir_path, file_size, "XLSX", "Failed to parse spreadsheet");
        return;
    };
    defer pkg.deinit();

    var wb = nanoxml.ooxml.Workbook.open(&pkg) catch {
        try renderFallback(io, allocator, stream, file_path, dir_path, file_size, "XLSX", "Not a valid workbook");
        return;
    };

    const sheet_count = wb.sheets.len;
    if (sheet_count == 0) {
        try renderFallback(io, allocator, stream, file_path, dir_path, file_size, "XLSX", "No sheets found");
        return;
    }

    // Collect sheet data
    const SheetInfo = struct {
        name: []const u8,
        rows: []const []const []const u8,
    };

    var sheets = std.ArrayList(SheetInfo).initCapacity(allocator, sheet_count) catch return;
    defer {
        for (sheets.items) |sheet| {
            for (sheet.rows) |row| {
                for (row) |cell| allocator.free(cell);
                allocator.free(row);
            }
            allocator.free(sheet.rows);
        }
        sheets.deinit(allocator);
    }

    for (0..sheet_count) |i| {
        var csv_buf: std.ArrayList(u8) = .empty;
        wb.sheetToCsv(allocator, i, &csv_buf) catch continue;
        defer csv_buf.deinit(allocator);

        // Parse CSV into rows
        var rows = std.ArrayList([]const []const u8).initCapacity(allocator, 64) catch continue;

        var line_iter = std.mem.splitScalar(u8, csv_buf.items, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            var cells = std.ArrayList([]const u8).initCapacity(allocator, 16) catch break;

            var in_quotes = false;
            var field_start: usize = 0;
            for (line, 0..) |c, ci| {
                if (c == '"') {
                    in_quotes = !in_quotes;
                } else if (c == ',' and !in_quotes) {
                    const raw = line[field_start..ci];
                    const unquoted = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
                        raw[1 .. raw.len - 1]
                    else
                        raw;
                    const cell = allocator.dupe(u8, unquoted) catch "";
                    cells.append(allocator, cell) catch break;
                    field_start = ci + 1;
                }
            }
            if (field_start <= line.len) {
                const raw = line[field_start..];
                const unquoted = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
                    raw[1 .. raw.len - 1]
                else
                    raw;
                const cell = allocator.dupe(u8, unquoted) catch "";
                cells.append(allocator, cell) catch break;
            }

            const row = cells.toOwnedSlice(allocator) catch &[_][]const u8{};
            rows.append(allocator, row) catch break;
        }

        sheets.append(allocator, .{
            .name = wb.sheets[i].name,
            .rows = rows.toOwnedSlice(allocator) catch &[_][]const []const u8{},
        }) catch break;
    }

    if (sheets.items.len == 0) {
        try renderFallback(io, allocator, stream, file_path, dir_path, file_size, "XLSX", "No data found");
        return;
    }

    // Extract embedded images
    var images = extractMediaImages(&pkg, allocator) catch std.ArrayList(ImageInfo){};
    defer {
        for (images.items) |img| allocator.free(img.base64_data);
        images.deinit(allocator);
    }
    const gallery_html = buildImageGalleryHtml(allocator, &images) catch "";
    defer if (gallery_html.len > 0) allocator.free(gallery_html);

    // Build sheet names JSON
    var names_json = std.ArrayList(u8).initCapacity(allocator, 128) catch return;
    defer names_json.deinit(allocator);
    names_json.appendSlice(allocator, "[") catch return;
    for (sheets.items, 0..) |s, idx| {
        if (idx > 0) names_json.appendSlice(allocator, ",") catch return;
        names_json.append(allocator, '"') catch return;
        for (s.name) |c| {
            switch (c) {
                '"' => names_json.appendSlice(allocator, "\\\"") catch return,
                '\\' => names_json.appendSlice(allocator, "\\\\") catch return,
                else => names_json.append(allocator, c) catch return,
            }
        }
        names_json.append(allocator, '"') catch return;
    }
    names_json.appendSlice(allocator, "]") catch return;

    const image_count_str = std.fmt.allocPrint(allocator, "{d}", .{images.items.len}) catch "0";
    defer if (image_count_str.len > 1) allocator.free(image_count_str);

    const filename = std.fs.path.basename(file_path);
    const parent_dir = buildParentDir(allocator, dir_path);
    defer if (parent_dir.len > 1 and !std.mem.startsWith(u8, dir_path, "/")) allocator.free(parent_dir);

    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, file_size);

    var write_buf: [65536]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n");

    // Build table HTML for each sheet
    var table_html = std.ArrayList(u8).initCapacity(allocator, 8192) catch return;
    defer table_html.deinit(allocator);

    for (sheets.items, 0..) |sheet, si| {
        const si_str = std.fmt.allocPrint(allocator, "{d}", .{si}) catch "0";
        defer allocator.free(si_str);

        table_html.appendSlice(allocator, "<div class=\"sheet\" id=\"sheet-") catch return;
        table_html.appendSlice(allocator, si_str) catch return;
        table_html.appendSlice(allocator, if (si == 0) "\" style=\"display:block\">" else "\" style=\"display:none\">") catch return;
        table_html.appendSlice(allocator, "<table><thead>") catch return;

        if (sheet.rows.len > 0) {
            table_html.appendSlice(allocator, "<tr>") catch return;
            for (sheet.rows[0]) |cell| {
                table_html.appendSlice(allocator, "<th>") catch return;
                const esc = htmlEscape(allocator, cell) catch cell;
                table_html.appendSlice(allocator, esc) catch return;
                if (esc.ptr != cell.ptr) allocator.free(esc);
                table_html.appendSlice(allocator, "</th>") catch return;
            }
            table_html.appendSlice(allocator, "</tr>") catch return;
        }
        table_html.appendSlice(allocator, "</thead><tbody>") catch return;

        for (1..sheet.rows.len) |ri| {
            table_html.appendSlice(allocator, "<tr>") catch return;
            for (sheet.rows[ri]) |cell| {
                table_html.appendSlice(allocator, "<td>") catch return;
                const esc = htmlEscape(allocator, cell) catch cell;
                table_html.appendSlice(allocator, esc) catch return;
                if (esc.ptr != cell.ptr) allocator.free(esc);
                table_html.appendSlice(allocator, "</td>") catch return;
            }
            table_html.appendSlice(allocator, "</tr>") catch return;
        }
        table_html.appendSlice(allocator, "</tbody></table></div>") catch return;
    }

    const html = try std.fmt.allocPrint(allocator, xlsx_html_template, .{
        filename, parent_dir, filename, size_str, image_count_str, table_html.items, gallery_html, names_json.items,
    });
    defer allocator.free(html);

    try writer.interface.writeAll(html);
    try writer.interface.flush();
}

fn renderPptxPreview(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file_bytes: []const u8,
    file_path: []const u8,
    dir_path: []const u8,
    file_size: u64,
) !void {
    var pkg = nanoxml.opc.Package.open(allocator, file_bytes) catch {
        try renderFallback(io, allocator, stream, file_path, dir_path, file_size, "PPTX", "Failed to parse presentation");
        return;
    };
    defer pkg.deinit();

    var pres = nanoxml.ooxml.Presentation.open(&pkg) catch {
        try renderFallback(io, allocator, stream, file_path, dir_path, file_size, "PPTX", "Not a valid presentation");
        return;
    };

    const slide_count = pres.slides.len;
    if (slide_count == 0) {
        try renderFallback(io, allocator, stream, file_path, dir_path, file_size, "PPTX", "No slides found");
        return;
    }

    // Collect slide content with inline images
    var slides = std.ArrayList(SlideContent).initCapacity(allocator, slide_count) catch return;
    defer {
        for (slides.items) |slide| {
            for (slide.text_segments) |t| allocator.free(t);
            allocator.free(slide.text_segments);
            for (slide.images) |img| allocator.free(img.base64_data);
            allocator.free(slide.images);
        }
        slides.deinit(allocator);
    }

    for (0..slide_count) |i| {
        const slide = extractPptxSlideWithImages(&pkg, allocator, pres.slides[i]) catch continue;
        slides.append(allocator, slide) catch {
            // Free on error
            for (slide.text_segments) |t| allocator.free(t);
            allocator.free(slide.text_segments);
            for (slide.images) |img| allocator.free(img.base64_data);
            allocator.free(slide.images);
            break;
        };
    }

    if (slides.items.len == 0) {
        try renderFallback(io, allocator, stream, file_path, dir_path, file_size, "PPTX", "No content found");
        return;
    }

    // Extract embedded images for gallery fallback
    var images = extractMediaImages(&pkg, allocator) catch std.ArrayList(ImageInfo){};
    defer {
        for (images.items) |img| allocator.free(img.base64_data);
        images.deinit(allocator);
    }
    const gallery_html = buildImageGalleryHtml(allocator, &images) catch "";
    defer if (gallery_html.len > 0) allocator.free(gallery_html);

    const image_count_str = std.fmt.allocPrint(allocator, "{d}", .{images.items.len}) catch "0";
    defer if (image_count_str.len > 1) allocator.free(image_count_str);

    const filename = std.fs.path.basename(file_path);
    const parent_dir = buildParentDir(allocator, dir_path);
    defer if (parent_dir.len > 1 and !std.mem.startsWith(u8, dir_path, "/")) allocator.free(parent_dir);

    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, file_size);

    var write_buf: [65536]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n");

    // Build slides JSON with inline HTML content
    var slides_json = std.ArrayList(u8).initCapacity(allocator, 4096) catch return;
    defer slides_json.deinit(allocator);
    slides_json.appendSlice(allocator, "[") catch return;
    for (slides.items, 0..) |slide, si| {
        if (si > 0) slides_json.appendSlice(allocator, ",") catch return;
        slides_json.appendSlice(allocator, "\"") catch return;

        // Build HTML content for this slide
        const slide_html = buildSlideContentHtml(allocator, &slide) catch "";
        defer if (slide_html.len > 0) allocator.free(slide_html);

        for (slide_html) |c| {
            switch (c) {
                '"' => slides_json.appendSlice(allocator, "\\\"") catch return,
                '\\' => slides_json.appendSlice(allocator, "\\\\") catch return,
                '\n' => slides_json.appendSlice(allocator, "\\n") catch return,
                '\r' => slides_json.appendSlice(allocator, "\\r") catch return,
                else => slides_json.append(allocator, c) catch return,
            }
        }
        slides_json.appendSlice(allocator, "\"") catch return;
    }
    slides_json.appendSlice(allocator, "]") catch return;

    const html = try std.fmt.allocPrint(allocator, pptx_html_template, .{
        filename, parent_dir, filename, size_str, image_count_str, slides.items.len, gallery_html, slides_json.items,
    });
    defer allocator.free(html);

    try writer.interface.writeAll(html);
    try writer.interface.flush();
}

fn renderFallback(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file_path: []const u8,
    dir_path: []const u8,
    file_size: u64,
    format: []const u8,
    error_msg: []const u8,
) !void {
    const filename = std.fs.path.basename(file_path);
    const parent_dir = buildParentDir(allocator, dir_path);
    defer if (parent_dir.len > 1 and !std.mem.startsWith(u8, dir_path, "/")) allocator.free(parent_dir);

    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, file_size);

    const html = try std.fmt.allocPrint(allocator, fallback_html_template, .{
        filename, filename, size_str, format, error_msg, file_path, parent_dir,
    });
    defer allocator.free(html);

    var write_buf: [65536]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n");
    try writer.interface.writeAll(html);
    try writer.interface.flush();
}

const docx_html_template =
    \\<!DOCTYPE html>
    \\<html lang="en"><head>
    \\  <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <meta name="color-scheme" content="light dark">
    \\<title>{s} - Document Preview</title>
    \\<style>
    \\    :root {{ --bg:#fff; --text:#24292e; --text2:#666; --border:#e2e8f0;
    \\      --hg1:#3b82f6; --hg2:#2563eb; --ht:#fff; --sb:#f8fafc; --mbg:#f8fafc;
    \\      --cbg:#f6f8fa; --cb:#d0d7de; --inv:#f1f5f9; }}
    \\    @media(prefers-color-scheme:dark){{ :root {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e;
    \\      --border:#30363d; --hg1:#3b82f6; --hg2:#2563eb; --ht:#fff; --sb:#161b22; --mbg:#161b22;
    \\      --cbg:#161b22; --cb:#30363d; --inv:#21262d; }} }}
    \\    body.dark-mode {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e; --border:#30363d;
    \\      --hg1:#3b82f6; --hg2:#2563eb; --ht:#fff; --sb:#161b22; --mbg:#161b22;
    \\      --cbg:#161b22; --cb:#30363d; --inv:#21262d; }}
    \\    * {{ box-sizing:border-box; }} html,body {{ margin:0; padding:0; }}
    \\    body {{ font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    \\      background:var(--bg); color:var(--text); line-height:1.6; transition:background .3s,color .3s; }}
    \\    .header {{ background:linear-gradient(135deg,var(--hg1),var(--hg2)); color:var(--ht);
    \\      padding:0; box-shadow:0 2px 8px rgba(0,0,0,.15); position:sticky; top:0; z-index:100; }}
    \\    .header-content {{ max-width:1400px; margin:0 auto; padding:16px 24px;
    \\      display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:12px; }}
    \\    .header-left {{ display:flex; align-items:center; gap:16px; }}
    \\    .header-title {{ font-size:1.25rem; font-weight:600; display:flex; align-items:center; gap:10px; }}
    \\    .back-btn {{ display:inline-flex; align-items:center; gap:6px; padding:8px 16px;
    \\      background:rgba(255,255,255,.15); border:1px solid rgba(255,255,255,.25);
    \\      border-radius:6px; color:var(--ht); text-decoration:none; font-size:.875rem;
    \\      font-weight:500; transition:all .2s; }}
    \\    .back-btn:hover {{ background:rgba(255,255,255,.25); transform:translateY(-1px); }}
    \\    .header-right {{ display:flex; align-items:center; gap:12px; }}
    \\    .theme-toggle {{ padding:8px 12px; background:rgba(255,255,255,.1);
    \\      border:1px solid rgba(255,255,255,.2); border-radius:6px; color:var(--ht);
    \\      font-size:.875rem; cursor:pointer; transition:all .2s; }}
    \\    .theme-toggle:hover {{ background:rgba(255,255,255,.2); }}
    \\    .container {{ max-width:1400px; margin:0 auto; display:flex; min-height:calc(100vh - 64px); }}
    \\    .sidebar {{ width:280px; flex-shrink:0; background:var(--sb); border-right:1px solid var(--border);
    \\      padding:20px; overflow-y:auto; max-height:calc(100vh - 64px); position:sticky; top:64px; }}
    \\    .sidebar-section {{ margin-bottom:24px; }}
    \\    .sidebar-title {{ font-size:.75rem; font-weight:600; text-transform:uppercase;
    \\      letter-spacing:.05em; color:var(--text2); margin-bottom:12px; padding-bottom:8px;
    \\      border-bottom:1px solid var(--border); }}
    \\    .file-meta {{ background:var(--mbg); border-radius:8px; padding:12px; font-size:.8125rem; }}
    \\    .file-meta-item {{ display:flex; justify-content:space-between; padding:4px 0;
    \\      border-bottom:1px solid var(--border); }}
    \\    .file-meta-item:last-child {{ border-bottom:none; }}
    \\    .file-meta-label {{ color:var(--text2); }}
    \\    .file-meta-value {{ font-weight:500; color:var(--text); }}
    \\    .main {{ flex:1; padding:32px 40px; max-width:900px; }}
    \\    .doc-body {{ font-size:15px; line-height:1.8; white-space:pre-wrap; word-wrap:break-word;
    \\      color:var(--text); background:var(--cbg); border:1px solid var(--cb);
    \\      border-radius:8px; padding:24px 32px; }}
    \\    .doc-body .inline-img {{ max-width:100%; height:auto; display:block; margin:16px 0;
    \\      border-radius:6px; cursor:pointer; transition:transform .2s,box-shadow .2s; }}
    \\    .doc-body .inline-img:hover {{ transform:scale(1.02); box-shadow:0 4px 16px rgba(0,0,0,.15); }}
    \\    .gallery-section {{ margin-top:24px; border:1px solid var(--border); border-radius:8px; overflow:hidden; }}
    \\    .gallery-header {{ display:flex; align-items:center; gap:8px; padding:12px 16px;
    \\      background:var(--mbg); cursor:pointer; user-select:none; font-weight:500; }}
    \\    .gallery-header:hover {{ background:var(--inv); }}
    \\    .gallery-toggle {{ font-size:.75rem; transition:transform .2s; }}
    \\    .gallery-toggle.open {{ transform:rotate(90deg); }}
    \\    .gallery-grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(180px,1fr));
    \\      gap:12px; padding:16px; }}
    \\    .gallery-item {{ cursor:pointer; border:1px solid var(--border); border-radius:6px;
    \\      overflow:hidden; transition:transform .2s,box-shadow .2s; }}
    \\    .gallery-item:hover {{ transform:translateY(-2px); box-shadow:0 4px 12px rgba(0,0,0,.15); }}
    \\    .gallery-item img {{ width:100%; height:140px; object-fit:cover; display:block; }}
    \\    .gallery-label {{ padding:6px 8px; font-size:.75rem; color:var(--text2);
    \\      white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }}
    \\    .lightbox {{ display:none; position:fixed; inset:0; z-index:1000;
    \\      background:rgba(0,0,0,.85); align-items:center; justify-content:center; }}
    \\    .lightbox.active {{ display:flex; }}
    \\    .lightbox img {{ max-width:90vw; max-height:90vh; object-fit:contain; }}
    \\    @media(max-width:1024px) {{ .sidebar {{ display:none; }} .main {{ padding:24px; max-width:100%; }} }}
    \\    @media(max-width:640px) {{ .header-content {{ padding:12px 16px; }} .header-title {{ font-size:1rem; }}
    \\      .main {{ padding:16px; }} .gallery-grid {{ grid-template-columns:repeat(auto-fill,minmax(120px,1fr)); }} }}
    \\</style></head><body>
    \\  <header class="header"><div class="header-content">
    \\    <div class="header-left">
    \\      <a href="{s}" class="back-btn"><span>&larr;</span> Back to directory</a>
    \\      <div class="header-title"><span>&#x1F4DD;</span><span>{s}</span></div>
    \\    </div>
    \\    <div class="header-right">
    \\      <button class="theme-toggle" onclick="toggleTheme()" id="themeToggle">&#x1F319; Dark</button>
    \\    </div>
    \\  </div></header>
    \\  <div class="container">
    \\    <aside class="sidebar"><div class="sidebar-section">
    \\      <div class="sidebar-title">File Info</div>
    \\      <div class="file-meta">
    \\        <div class="file-meta-item"><span class="file-meta-label">Size</span><span class="file-meta-value">{s}</span></div>
    \\        <div class="file-meta-item"><span class="file-meta-label">Type</span><span class="file-meta-value">DOCX Document</span></div>
    \\        <div class="file-meta-item"><span class="file-meta-label">Images</span><span class="file-meta-value">{s}</span></div>
    \\      </div>
    \\    </div></aside>
    \\    <main class="main"><div class="doc-body">{s}</div>{s}</main>
    \\  </div>
    \\<script>
    \\function toggleGallery(){{var g=document.getElementById('galleryGrid');var t=document.getElementById('galleryToggle');if(g.style.display==='none'){{g.style.display='grid';t.classList.add('open')}}else{{g.style.display='none';t.classList.remove('open')}}}}
    \\function openLightbox(el){{if(el&&el.src){{document.getElementById('lightboxImg').src=el.src;document.getElementById('lightbox').classList.add('active')}}}}
    \\function openLightboxIdx(i){{var imgs=document.querySelectorAll('.gallery-item img');if(imgs[i]){{document.getElementById('lightboxImg').src=imgs[i].src;document.getElementById('lightbox').classList.add('active')}}}}
    \\function closeLightbox(e){{if(e.target===document.getElementById('lightbox')||e.target===document.getElementById('lightboxImg')){{document.getElementById('lightbox').classList.remove('active')}}}}
    \\document.addEventListener('keydown',function(e){{if(e.key==='Escape')document.getElementById('lightbox').classList.remove('active')}});
    \\function toggleTheme(){{var d=document.body.classList.toggle('dark-mode');localStorage.setItem('theme',d?'dark':'light');updateUI()}}
    \\function updateUI(){{var d=document.body.classList.contains('dark-mode');var b=document.getElementById('themeToggle');if(b)b.textContent=d?'\u2600\uFE0F Light':'\u1F319 Dark'}}
    \\(function(){{var s=localStorage.getItem('theme');if(s==='dark')document.body.classList.add('dark-mode');else if(!s&&window.matchMedia('(prefers-color-scheme:dark)').matches)document.body.classList.add('dark-mode');updateUI()}})()
    \\</script></body></html>
    ;

const xlsx_html_template =
    \\<!DOCTYPE html>
    \\<html lang="en"><head>
    \\  <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <meta name="color-scheme" content="light dark">
    \\<title>{s} - Spreadsheet Preview</title>
    \\<style>
    \\    :root {{ --bg:#fff; --text:#24292e; --text2:#666; --border:#e2e8f0;
    \\      --hg1:#10b981; --hg2:#059669; --ht:#fff; --sb:#f8fafc; --mbg:#f8fafc;
    \\      --cbg:#fff; --cb:#d0d7de; --th:#f6f8fa; --tr:#f6f8fa; --st:#3b82f6; --inv:#f1f5f9; }}
    \\    @media(prefers-color-scheme:dark){{ :root {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e;
    \\      --border:#30363d; --hg1:#10b981; --hg2:#059669; --ht:#fff; --sb:#161b22; --mbg:#161b22;
    \\      --cbg:#0d1117; --cb:#30363d; --th:#161b22; --tr:#0d1117; --st:#3b82f6; --inv:#21262d; }} }}
    \\    body.dark-mode {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e; --border:#30363d;
    \\      --hg1:#10b981; --hg2:#059669; --ht:#fff; --sb:#161b22; --mbg:#161b22;
    \\      --cbg:#0d1117; --cb:#30363d; --th:#161b22; --tr:#0d1117; --st:#3b82f6; --inv:#21262d; }}
    \\    * {{ box-sizing:border-box; }} html,body {{ margin:0; padding:0; }}
    \\    body {{ font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    \\      background:var(--bg); color:var(--text); line-height:1.6; transition:background .3s,color .3s; }}
    \\    .header {{ background:linear-gradient(135deg,var(--hg1),var(--hg2)); color:var(--ht);
    \\      padding:0; box-shadow:0 2px 8px rgba(0,0,0,.15); position:sticky; top:0; z-index:100; }}
    \\    .header-content {{ max-width:1400px; margin:0 auto; padding:16px 24px;
    \\      display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:12px; }}
    \\    .header-left {{ display:flex; align-items:center; gap:16px; }}
    \\    .header-title {{ font-size:1.25rem; font-weight:600; display:flex; align-items:center; gap:10px; }}
    \\    .back-btn {{ display:inline-flex; align-items:center; gap:6px; padding:8px 16px;
    \\      background:rgba(255,255,255,.15); border:1px solid rgba(255,255,255,.25);
    \\      border-radius:6px; color:var(--ht); text-decoration:none; font-size:.875rem;
    \\      font-weight:500; transition:all .2s; }}
    \\    .back-btn:hover {{ background:rgba(255,255,255,.25); transform:translateY(-1px); }}
    \\    .header-right {{ display:flex; align-items:center; gap:12px; }}
    \\    .theme-toggle {{ padding:8px 12px; background:rgba(255,255,255,.1);
    \\      border:1px solid rgba(255,255,255,.2); border-radius:6px; color:var(--ht);
    \\      font-size:.875rem; cursor:pointer; transition:all .2s; }}
    \\    .theme-toggle:hover {{ background:rgba(255,255,255,.2); }}
    \\    .sheet-tabs {{ display:flex; gap:4px; padding:12px 24px; background:var(--sb);
    \\      border-bottom:1px solid var(--border); overflow-x:auto; }}
    \\    .gallery-section {{ margin-top:24px; border:1px solid var(--border); border-radius:8px; overflow:hidden; }}
    \\    .gallery-header {{ display:flex; align-items:center; gap:8px; padding:12px 16px;
    \\      background:var(--mbg); cursor:pointer; user-select:none; font-weight:500; }}
    \\    .gallery-header:hover {{ background:var(--inv); }}
    \\    .gallery-toggle {{ font-size:.75rem; transition:transform .2s; }}
    \\    .gallery-toggle.open {{ transform:rotate(90deg); }}
    \\    .gallery-grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(180px,1fr));
    \\      gap:12px; padding:16px; }}
    \\    .gallery-item {{ cursor:pointer; border:1px solid var(--border); border-radius:6px;
    \\      overflow:hidden; transition:transform .2s,box-shadow .2s; }}
    \\    .gallery-item:hover {{ transform:translateY(-2px); box-shadow:0 4px 12px rgba(0,0,0,.15); }}
    \\    .gallery-item img {{ width:100%; height:140px; object-fit:cover; display:block; }}
    \\    .gallery-label {{ padding:6px 8px; font-size:.75rem; color:var(--text2);
    \\      white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }}
    \\    .lightbox {{ display:none; position:fixed; inset:0; z-index:1000;
    \\      background:rgba(0,0,0,.85); align-items:center; justify-content:center; }}
    \\    .lightbox.active {{ display:flex; }}
    \\    .lightbox img {{ max-width:90vw; max-height:90vh; object-fit:contain; }}
    \\    .sheet-tab {{ padding:8px 16px; border:1px solid var(--border); border-bottom:none;
    \\      border-radius:8px 8px 0 0; background:var(--inv); color:var(--text2);
    \\      cursor:pointer; font-size:.8125rem; font-weight:500; white-space:nowrap; transition:all .2s; }}
    \\    .sheet-tab:hover {{ color:var(--text); background:var(--mbg); }}
    \\    .sheet-tab.active {{ background:var(--bg); color:var(--st); border-color:var(--st);
    \\      border-bottom:2px solid var(--bg); margin-bottom:-1px; }}
    \\    .container {{ max-width:1400px; margin:0 auto; padding:24px; overflow-x:auto; }}
    \\    table {{ width:max-content; min-width:100%; border-collapse:collapse; font-size:14px; }}
    \\    th,td {{ padding:8px 12px; border:1px solid var(--cb); text-align:left; white-space:nowrap; }}
    \\    th {{ font-weight:600; background:var(--th); position:sticky; top:0; z-index:1; }}
    \\    tr:nth-child(2n) {{ background:var(--tr); }}
    \\    tr:hover td {{ background:rgba(59,130,246,.06); }}
    \\    @media(max-width:640px) {{ .header-content {{ padding:12px 16px; }} .header-title {{ font-size:1rem; }}
    \\      .container {{ padding:16px; }} th,td {{ padding:6px 8px; font-size:13px; }} }}
    \\</style></head><body>
    \\  <header class="header"><div class="header-content">
    \\    <div class="header-left">
    \\      <a href="{s}" class="back-btn"><span>&larr;</span> Back</a>
    \\      <div class="header-title"><span>&#x1F4CA;</span><span>{s}</span><span style="font-size:.75rem;opacity:.7"> ({s})</span><span style="font-size:.75rem;opacity:.7"> | {s} images</span></div>
    \\    </div>
    \\    <div class="header-right">
    \\      <button class="theme-toggle" onclick="toggleTheme()" id="themeToggle">&#x1F319; Dark</button>
    \\    </div>
    \\  </div></header>
    \\  <div class="sheet-tabs" id="sheetTabs"></div>
    \\  <div class="container" id="sheetContent">{s}{s}</div>
    \\<script>
    \\var sheets={s};
    \\var tabs=document.getElementById('sheetTabs');
    \\sheets.forEach(function(n,i){{var t=document.createElement('div');t.className='sheet-tab'+(i===0?' active':'');t.textContent=n;t.onclick=function(){{document.querySelectorAll('.sheet-tab').forEach(function(x){{x.classList.remove('active')}});t.classList.add('active');document.querySelectorAll('.sheet').forEach(function(s,j){{s.style.display=j===i?'block':'none'}})}};tabs.appendChild(t)}});
    \\function toggleGallery(){{var g=document.getElementById('galleryGrid');var t=document.getElementById('galleryToggle');if(g.style.display==='none'){{g.style.display='grid';t.classList.add('open')}}else{{g.style.display='none';t.classList.remove('open')}}}}
    \\function openLightbox(el){{if(el&&el.src){{document.getElementById('lightboxImg').src=el.src;document.getElementById('lightbox').classList.add('active')}}}}
    \\function openLightboxIdx(i){{var imgs=document.querySelectorAll('.gallery-item img');if(imgs[i]){{document.getElementById('lightboxImg').src=imgs[i].src;document.getElementById('lightbox').classList.add('active')}}}}
    \\function closeLightbox(e){{if(e.target===document.getElementById('lightbox')||e.target===document.getElementById('lightboxImg')){{document.getElementById('lightbox').classList.remove('active')}}}}
    \\document.addEventListener('keydown',function(e){{if(e.key==='Escape')document.getElementById('lightbox').classList.remove('active')}});
    \\function toggleTheme(){{var d=document.body.classList.toggle('dark-mode');localStorage.setItem('theme',d?'dark':'light');updateUI()}}
    \\function updateUI(){{var d=document.body.classList.contains('dark-mode');var b=document.getElementById('themeToggle');if(b)b.textContent=d?'\u2600\uFE0F Light':'\u1F319 Dark'}}
    \\(function(){{var s=localStorage.getItem('theme');if(s==='dark')document.body.classList.add('dark-mode');else if(!s&&window.matchMedia('(prefers-color-scheme:dark)').matches)document.body.classList.add('dark-mode');updateUI()}})()
    \\</script></body></html>
    ;

const pptx_html_template =
    \\<!DOCTYPE html>
    \\<html lang="en"><head>
    \\  <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <meta name="color-scheme" content="light dark">
    \\<title>{s} - Presentation Preview</title>
    \\<style>
    \\    :root {{ --bg:#fff; --text:#24292e; --text2:#666; --border:#e2e8f0;
    \\      --hg1:#8b5cf6; --hg2:#7c3aed; --ht:#fff; --sb:#f8fafc;
    \\      --slide-bg:#fff; --shadow:0 4px 24px rgba(0,0,0,.12);
    \\      --pg:#64748b; --pb:#3b82f6; --pbh:#2563eb; --inv:#f1f5f9; }}
    \\    @media(prefers-color-scheme:dark){{ :root {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e;
    \\      --border:#30363d; --hg1:#8b5cf6; --hg2:#7c3aed; --ht:#fff; --sb:#161b22;
    \\      --slide-bg:#161b22; --shadow:0 4px 24px rgba(0,0,0,.4);
    \\      --pg:#8b949e; --pb:#3b82f6; --pbh:#2563eb; --inv:#21262d; }} }}
    \\    body.dark-mode {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e; --border:#30363d;
    \\      --hg1:#8b5cf6; --hg2:#7c3aed; --ht:#fff; --sb:#161b22;
    \\      --slide-bg:#161b22; --shadow:0 4px 24px rgba(0,0,0,.4);
    \\      --pg:#8b949e; --pb:#3b82f6; --pbh:#2563eb; --inv:#21262d; }}
    \\    * {{ box-sizing:border-box; }} html,body {{ margin:0; padding:0; }}
    \\    body {{ font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    \\      background:var(--bg); color:var(--text); line-height:1.6; transition:background .3s,color .3s; }}
    \\    .header {{ background:linear-gradient(135deg,var(--hg1),var(--hg2)); color:var(--ht);
    \\      padding:0; box-shadow:0 2px 8px rgba(0,0,0,.15); position:sticky; top:0; z-index:100; }}
    \\    .header-content {{ max-width:1400px; margin:0 auto; padding:16px 24px;
    \\      display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:12px; }}
    \\    .header-left {{ display:flex; align-items:center; gap:16px; }}
    \\    .header-title {{ font-size:1.25rem; font-weight:600; display:flex; align-items:center; gap:10px; }}
    \\    .back-btn {{ display:inline-flex; align-items:center; gap:6px; padding:8px 16px;
    \\      background:rgba(255,255,255,.15); border:1px solid rgba(255,255,255,.25);
    \\      border-radius:6px; color:var(--ht); text-decoration:none; font-size:.875rem;
    \\      font-weight:500; transition:all .2s; }}
    \\    .back-btn:hover {{ background:rgba(255,255,255,.25); transform:translateY(-1px); }}
    \\    .header-right {{ display:flex; align-items:center; gap:12px; }}
    \\    .theme-toggle {{ padding:8px 12px; background:rgba(255,255,255,.1);
    \\      border:1px solid rgba(255,255,255,.2); border-radius:6px; color:var(--ht);
    \\      font-size:.875rem; cursor:pointer; transition:all .2s; }}
    \\    .theme-toggle:hover {{ background:rgba(255,255,255,.2); }}
    \\    .viewer {{ max-width:1000px; margin:0 auto; padding:32px 24px; }}
    \\    .slide {{ background:var(--slide-bg); border:1px solid var(--border); border-radius:12px;
    \\      box-shadow:var(--shadow); padding:48px; min-height:400px; margin-bottom:24px;
    \\      font-size:18px; line-height:1.8; white-space:pre-wrap; }}
    \\    .slide .slide-img {{ max-width:100%; height:auto; display:block; margin:16px auto;
    \\      border-radius:8px; cursor:pointer; transition:transform .2s,box-shadow .2s;
    \\      max-height:400px; object-fit:contain; }}
    \\    .slide .slide-img:hover {{ transform:scale(1.02); box-shadow:0 4px 16px rgba(0,0,0,.2); }}
    \\    .slide .slide-images {{ display:flex; flex-wrap:wrap; gap:12px; justify-content:center; margin-top:16px; }}
    \\    .nav {{ display:flex; align-items:center; justify-content:center; gap:16px; }}
    \\    .nav button {{ padding:10px 24px; background:var(--pb); color:#fff; border:none;
    \\      border-radius:8px; font-size:.875rem; font-weight:500; cursor:pointer; transition:background .2s; }}
    \\    .nav button:hover {{ background:var(--pbh); }}
    \\    .nav button:disabled {{ opacity:.4; cursor:not-allowed; }}
    \\    .nav .info {{ color:var(--pg); font-size:.875rem; min-width:100px; text-align:center; }}
    \\    .gallery-section {{ margin-top:24px; border:1px solid var(--border); border-radius:8px; overflow:hidden; }}
    \\    .gallery-header {{ display:flex; align-items:center; gap:8px; padding:12px 16px;
    \\      background:var(--mbg); cursor:pointer; user-select:none; font-weight:500; }}
    \\    .gallery-header:hover {{ background:var(--inv); }}
    \\    .gallery-toggle {{ font-size:.75rem; transition:transform .2s; }}
    \\    .gallery-toggle.open {{ transform:rotate(90deg); }}
    \\    .gallery-grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(180px,1fr));
    \\      gap:12px; padding:16px; }}
    \\    .gallery-item {{ cursor:pointer; border:1px solid var(--border); border-radius:6px;
    \\      overflow:hidden; transition:transform .2s,box-shadow .2s; }}
    \\    .gallery-item:hover {{ transform:translateY(-2px); box-shadow:0 4px 12px rgba(0,0,0,.15); }}
    \\    .gallery-item img {{ width:100%; height:140px; object-fit:cover; display:block; }}
    \\    .gallery-label {{ padding:6px 8px; font-size:.75rem; color:var(--text2);
    \\      white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }}
    \\    .lightbox {{ display:none; position:fixed; inset:0; z-index:1000;
    \\      background:rgba(0,0,0,.85); align-items:center; justify-content:center; }}
    \\    .lightbox.active {{ display:flex; }}
    \\    .lightbox img {{ max-width:90vw; max-height:90vh; object-fit:contain; }}
    \\    @media(max-width:640px) {{ .header-content {{ padding:12px 16px; }} .header-title {{ font-size:1rem; }}
    \\      .viewer {{ padding:16px; }} .slide {{ padding:24px; min-height:200px; font-size:16px; }} }}
    \\</style></head><body>
    \\  <header class="header"><div class="header-content">
    \\    <div class="header-left">
    \\      <a href="{s}" class="back-btn"><span>&larr;</span> Back</a>
    \\      <div class="header-title"><span>&#x1F4F9;</span><span>{s}</span><span style="font-size:.75rem;opacity:.7"> ({s})</span><span style="font-size:.75rem;opacity:.7"> | {s} images</span></div>
    \\    </div>
    \\    <div class="header-right">
    \\      <button class="theme-toggle" onclick="toggleTheme()" id="themeToggle">&#x1F319; Dark</button>
    \\    </div>
    \\  </div></header>
    \\  <div class="viewer">
    \\    <div class="slide" id="slideContent"></div>
    \\    <div class="nav">
    \\      <button id="prevBtn" onclick="go(-1)">&larr; Previous</button>
    \\      <span class="info" id="slideInfo">1 / {d}</span>
    \\      <button id="nextBtn" onclick="go(1)">Next &rarr;</button>
    \\    </div>
    \\    {s}
    \\  </div>
    \\<script>
    \\var slides={s};var cur=0;
    \\function render(){{document.getElementById('slideContent').innerHTML=slides[cur];document.getElementById('slideInfo').textContent=(cur+1)+' / '+slides.length;document.getElementById('prevBtn').disabled=cur===0;document.getElementById('nextBtn').disabled=cur===slides.length-1}}
    \\function go(d){{cur=Math.max(0,Math.min(slides.length-1,cur+d));render()}}
    \\document.addEventListener('keydown',function(e){{if(e.key==='ArrowLeft')go(-1);if(e.key==='ArrowRight')go(1);if(e.key==='Home'){{cur=0;render()}}if(e.key==='End'){{cur=slides.length-1;render()}}}});
    \\function toggleGallery(){{var g=document.getElementById('galleryGrid');var t=document.getElementById('galleryToggle');if(g.style.display==='none'){{g.style.display='grid';t.classList.add('open')}}else{{g.style.display='none';t.classList.remove('open')}}}}
    \\function openLightbox(el){{if(el&&el.src){{document.getElementById('lightboxImg').src=el.src;document.getElementById('lightbox').classList.add('active')}}}}
    \\function openLightboxIdx(i){{var imgs=document.querySelectorAll('.gallery-item img');if(imgs[i]){{document.getElementById('lightboxImg').src=imgs[i].src;document.getElementById('lightbox').classList.add('active')}}}}
    \\function closeLightbox(e){{if(e.target===document.getElementById('lightbox')||e.target===document.getElementById('lightboxImg')){{document.getElementById('lightbox').classList.remove('active')}}}}
    \\document.addEventListener('keydown',function(e){{if(e.key==='Escape')document.getElementById('lightbox').classList.remove('active')}});
    \\function toggleTheme(){{var d=document.body.classList.toggle('dark-mode');localStorage.setItem('theme',d?'dark':'light');updateUI()}}
    \\function updateUI(){{var d=document.body.classList.contains('dark-mode');var b=document.getElementById('themeToggle');if(b)b.textContent=d?'\u2600\uFE0F Light':'\u1F319 Dark'}}
    \\(function(){{var s=localStorage.getItem('theme');if(s==='dark')document.body.classList.add('dark-mode');else if(!s&&window.matchMedia('(prefers-color-scheme:dark)').matches)document.body.classList.add('dark-mode');updateUI()}})()
    \\render();
    \\</script></body></html>
    ;

const fallback_html_template =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>{s}</title>
    \\<style>
    \\body{{font-family:system-ui,sans-serif;background:#f8fafc;color:#1e293b;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}}
    \\.card{{background:#fff;border-radius:12px;box-shadow:0 4px 12px rgba(0,0,0,.1);padding:48px;max-width:500px;text-align:center}}
    \\.icon{{font-size:3rem;margin-bottom:16px}}
    \\h2{{margin:0 0 8px;font-size:1.25rem}}
    \\.meta{{color:#64748b;font-size:.875rem;margin:16px 0}}
    \\.back{{display:inline-block;margin-top:16px;padding:10px 24px;background:#3b82f6;color:#fff;border-radius:8px;text-decoration:none;font-weight:500;transition:background .2s}}
    \\.back:hover{{background:#2563eb}}
    \\.err{{color:#ef4444;font-size:.8125rem;margin-top:12px}}
    \\</style></head>
    \\<body><div class="card">
    \\<div class="icon">&#x1F4C4;</div>
    \\<h2>{s}</h2>
    \\<div class="meta">{s} &bull; {s}</div>
    \\<div class="err">{s}</div>
    \\<p style="font-size:.875rem;color:#64748b">You can download the file instead.</p>
    \\<a href="/download?file={s}" class="back">&#x2B07; Download</a>
    \\<br><a href="{s}" style="color:#3b82f6;font-size:.875rem">&larr; Back to directory</a>
    \\</div></body></html>
    ;

fn buildParentDir(allocator: std.mem.Allocator, dir_path: []const u8) []const u8 {
    if (std.mem.eql(u8, dir_path, ".") or dir_path.len == 0) return "/";
    if (std.mem.startsWith(u8, dir_path, "/")) return dir_path;
    const with_slash = allocator.alloc(u8, dir_path.len + 1) catch return "/";
    with_slash[0] = '/';
    @memcpy(with_slash[1..], dir_path);
    return with_slash;
}

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

fn htmlEscape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var count: usize = 0;
    for (input) |c| {
        switch (c) {
            '&' => count += 4,
            '<' => count += 3,
            '>' => count += 3,
            '"' => count += 5,
            else => {},
        }
    }
    if (count == 0) return input;

    const result = try allocator.alloc(u8, input.len + count);
    var j: usize = 0;
    for (input) |c| {
        switch (c) {
            '&' => { @memcpy(result[j .. j + 5], "&amp;"); j += 5; },
            '<' => { @memcpy(result[j .. j + 4], "&lt;"); j += 4; },
            '>' => { @memcpy(result[j .. j + 4], "&gt;"); j += 4; },
            '"' => { @memcpy(result[j .. j + 6], "&quot;"); j += 6; },
            else => { result[j] = c; j += 1; },
        }
    }
    return result;
}
