# Features

## Static File Serving

The server serves static files with automatic MIME type detection based on file extensions.

### Supported MIME Types

#### Text Formats

| Extension | MIME Type |
|-----------|-----------|
| `.html`, `.htm` | `text/html; charset=utf-8` |
| `.css` | `text/css` |
| `.js` | `application/javascript` |
| `.txt` | `text/plain; charset=utf-8` |

#### Image Formats

| Extension | MIME Type |
|-----------|-----------|
| `.jpg`, `.jpeg` | `image/jpeg` |
| `.png` | `image/png` |
| `.gif` | `image/gif` |
| `.webp` | `image/webp` |
| `.avif` | `image/avif` |
| `.svg` | `image/svg+xml` |

#### Video Formats

| Extension | MIME Type |
|-----------|-----------|
| `.mp4` | `video/mp4` |
| `.webm` | `video/webm` |
| `.mkv` | `video/x-matroska` |

#### Audio Formats

| Extension | MIME Type |
|-----------|-----------|
| `.mp3` | `audio/mpeg` |
| `.wav` | `audio/wav` |
| `.ogg` | `audio/ogg` |

#### Documents

| Extension | MIME Type |
|-----------|-----------|
| `.pdf` | `application/pdf` |
| `.zip` | `application/zip` |

Unknown file types are served as `application/octet-stream`.

## Office Document Preview

The server provides rich preview for Office Open XML documents (DOCX, XLSX, XLSM, PPTX) with support for files up to 50 MB.

### DOCX (Word)

- **Inline image rendering** — Images are displayed at their actual positions within the document text, not in a separate gallery
- **Text extraction** — Full document text with paragraph structure preserved
- **Image gallery** — Fallback gallery for images that cannot be positioned inline
- **Lightbox viewer** — Click any image to view it in full size

### XLSX / XLSM (Excel)

- **Multi-sheet support** — Tab-based navigation between worksheets
- **Table rendering** — Full spreadsheet data with headers and cell content
- **Image gallery** — Embedded images displayed in a collapsible gallery

### PPTX (PowerPoint)

- **Slide navigation** — Arrow keys and buttons to navigate between slides
- **Inline images** — Images displayed within each slide's content
- **Text extraction** — Slide text content with structure preserved
- **Lightbox viewer** — Click images to view in full size

## PDF Preview

The server provides rich preview for PDF documents (up to 50 MB) powered by [zpdf](https://github.com/EdmondFrank/zpdf), a high-performance PDF text extraction library.

### Text Extraction

- **Markdown rendering** — PDF text is extracted and converted to Markdown, preserving headings, paragraphs, and structure
- **Page limit** — First 200 pages are extracted for preview
- **Permissive parsing** — Continues extraction even on malformed PDFs

### Document Metadata

The sidebar displays PDF metadata extracted from the document:

- **Title** — From PDF /Info dictionary
- **Author** — From PDF /Info dictionary
- **Page count** — Total pages in the document
- **File size** — Human-readable size

### Outline / Table of Contents

If the PDF contains a `/Outlines` tree (bookmarks), the sidebar displays a navigable table of contents with hierarchical indentation.

### View Modes

- **Rendered view** — Markdown rendered client-side via marked.js with syntax highlighting
- **Source view** — Raw extracted Markdown text
- **Light/dark theme** — Toggle persisted to `localStorage`

### Fallback

PDFs that fail to parse display a fallback page with document metadata and a download button.

## Directory Listings

When accessing a directory path, the server generates an HTML listing with:

- **File/folder names** - Clickable links for navigation
- **File sizes** - Human-readable format (B, KB, MB, GB)
- **Parent directory link** - `..` for navigation
- **Sorted output** - Directories first, then alphabetically

### Example Output

```html
<h1>Directory listing: /project</h1>
<ul>
  <li><a href=".." class="directory">..</a><span class="size">-</span></li>
  <li><a href="/src" class="directory">src/</a><span class="size">-</span></li>
  <li><a href="/README.md" class="file">README.md</a><span class="size">2.5 KB</span></li>
</ul>
```

## Range Requests

The server supports HTTP Range requests for partial content delivery, enabling:

- **Video streaming** - Seek support in video players
- **Audio streaming** - Play audio files without downloading
- **Resumable downloads** - Resume interrupted downloads
- **Bandwidth efficiency** - Stream only needed portions

### Usage Example

Request:
```http
GET /video.mp4 HTTP/1.1
Host: localhost:8080
Range: bytes=0-1023
```

Response:
```http
HTTP/1.1 206 Partial Content
Content-Type: video/mp4
Content-Length: 1024
Content-Range: bytes 0-1023/10485760
Accept-Ranges: bytes

[binary data]
```

## HTTP Methods

| Method | Support |
|--------|---------|
| `GET` | ✅ Full support |
| `HEAD` | ✅ Full support |
| `POST` | ❌ Not supported |
| `PUT` | ❌ Not supported |
| `DELETE` | ❌ Not supported |

## Logging

Requests are logged to stdout in a simple format:

```
[2026-02-17 15:30:45] GET /index.html 200
[2026-02-17 15:30:46] GET /style.css 200
[2026-02-17 15:30:47] GET /notfound.html 404
```

## Response Headers

The server includes these headers in responses:

| Header | Description |
|--------|-------------|
| `Content-Type` | MIME type of the content |
| `Content-Length` | Size in bytes |
| `Accept-Ranges` | Indicates range request support |
| `Content-Disposition` | Filename for downloads |

### Example Response

```http
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Content-Length: 1234
Accept-Ranges: bytes
Content-Disposition: inline; filename="index.html"
```
