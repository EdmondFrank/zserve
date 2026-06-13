const std = @import("std");

pub fn getMimeType(path: []const u8) []const u8 {
    const filename = std.fs.path.basename(path);

    // Filename-based detection for config/package manager files
    // Ruby
    if (std.mem.eql(u8, filename, "Gemfile") or
        std.mem.eql(u8, filename, "Gemfile.lock") or
        std.mem.eql(u8, filename, "Rakefile") or
        std.mem.eql(u8, filename, "Vagrantfile"))
        return "text/x-ruby; charset=utf-8";

    // Go modules
    if (std.mem.eql(u8, filename, "go.mod") or
        std.mem.eql(u8, filename, "go.sum"))
        return "text/x-go; charset=utf-8";

    // Rust
    if (std.mem.eql(u8, filename, "Cargo.toml") or
        std.mem.eql(u8, filename, "Cargo.lock"))
        return "application/toml";

    // Node.js
    if (std.mem.eql(u8, filename, "package.json") or
        std.mem.eql(u8, filename, "package-lock.json") or
        std.mem.eql(u8, filename, "tsconfig.json") or
        std.mem.eql(u8, filename, "jsconfig.json") or
        std.mem.eql(u8, filename, ".babelrc") or
        std.mem.eql(u8, filename, ".eslintrc.json") or
        std.mem.eql(u8, filename, ".prettierrc.json"))
        return "application/json";

    if (std.mem.eql(u8, filename, "yarn.lock") or
        std.mem.eql(u8, filename, "pnpm-lock.yaml") or
        std.mem.eql(u8, filename, ".eslintrc.yml") or
        std.mem.eql(u8, filename, ".prettierrc.yml") or
        std.mem.eql(u8, filename, ".eslintrc.yaml") or
        std.mem.eql(u8, filename, ".prettierrc.yaml"))
        return "application/yaml";

    if (std.mem.eql(u8, filename, ".npmrc") or
        std.mem.eql(u8, filename, ".yarnrc") or
        std.mem.eql(u8, filename, ".nvmrc"))
        return "text/x-ini; charset=utf-8";

    // Python
    if (std.mem.eql(u8, filename, "requirements.txt") or
        std.mem.eql(u8, filename, "requirements-dev.txt") or
        std.mem.eql(u8, filename, "constraints.txt"))
        return "text/plain; charset=utf-8";

    if (std.mem.eql(u8, filename, "setup.py") or
        std.mem.eql(u8, filename, "setup.cfg") or
        std.mem.eql(u8, filename, "manage.py"))
        return "text/x-python; charset=utf-8";

    if (std.mem.eql(u8, filename, "pyproject.toml") or
        std.mem.eql(u8, filename, "Pipfile") or
        std.mem.eql(u8, filename, "Pipfile.lock"))
        return "application/toml";

    // PHP
    if (std.mem.eql(u8, filename, "composer.json") or
        std.mem.eql(u8, filename, "composer.lock"))
        return "application/json";

    // Java/Kotlin
    if (std.mem.eql(u8, filename, "pom.xml"))
        return "text/xml; charset=utf-8";

    if (std.mem.eql(u8, filename, "build.gradle") or
        std.mem.eql(u8, filename, "build.gradle.kts") or
        std.mem.eql(u8, filename, "settings.gradle") or
        std.mem.eql(u8, filename, "settings.gradle.kts"))
        return "text/x-kotlin; charset=utf-8";

    // Build tools
    if (std.mem.eql(u8, filename, "Makefile") or
        std.mem.eql(u8, filename, "makefile") or
        std.mem.eql(u8, filename, "GNUmakefile"))
        return "text/x-makefile; charset=utf-8";

    if (std.mem.eql(u8, filename, "CMakeLists.txt"))
        return "text/x-cmake; charset=utf-8";

    if (std.mem.eql(u8, filename, "Justfile") or
        std.mem.eql(u8, filename, "justfile"))
        return "text/x-justfile; charset=utf-8";

    if (std.mem.eql(u8, filename, "Taskfile.yml") or
        std.mem.eql(u8, filename, "Taskfile.yaml"))
        return "application/yaml";

    // Docker
    if (std.mem.eql(u8, filename, "Dockerfile") or
        std.mem.eql(u8, filename, "dockerfile"))
        return "text/x-dockerfile; charset=utf-8";

    if (std.mem.eql(u8, filename, "docker-compose.yml") or
        std.mem.eql(u8, filename, "docker-compose.yaml") or
        std.mem.eql(u8, filename, "compose.yml") or
        std.mem.eql(u8, filename, "compose.yaml"))
        return "application/yaml";

    // Git
    if (std.mem.eql(u8, filename, ".gitignore") or
        std.mem.eql(u8, filename, ".gitattributes") or
        std.mem.eql(u8, filename, ".gitmodules"))
        return "text/plain; charset=utf-8";

    // Docker ignore
    if (std.mem.eql(u8, filename, ".dockerignore"))
        return "text/plain; charset=utf-8";

    // Editor config
    if (std.mem.eql(u8, filename, ".editorconfig"))
        return "text/x-ini; charset=utf-8";

    // Zig
    if (std.mem.eql(u8, filename, "build.zig") or
        std.mem.eql(u8, filename, "build.zig.zon"))
        return "text/x-zig; charset=utf-8";

    // Elixir
    if (std.mem.eql(u8, filename, "mix.exs") or
        std.mem.eql(u8, filename, "mix.lock"))
        return "text/x-elixir; charset=utf-8";

    // Dart/Flutter
    if (std.mem.eql(u8, filename, "pubspec.yaml") or
        std.mem.eql(u8, filename, "pubspec.lock"))
        return "application/yaml";

    // iOS
    if (std.mem.eql(u8, filename, "Podfile") or
        std.mem.eql(u8, filename, "Podfile.lock"))
        return "text/x-ruby; charset=utf-8";

    if (std.mem.eql(u8, filename, "Cartfile") or
        std.mem.eql(u8, filename, "Cartfile.resolved"))
        return "text/plain; charset=utf-8";

    // Erlang
    if (std.mem.eql(u8, filename, "rebar.config") or
        std.mem.eql(u8, filename, "rebar.lock"))
        return "application/erlang; charset=utf-8";

    // Haskell
    if (std.mem.eql(u8, filename, "cabal.project") or
        std.mem.eql(u8, filename, "cabal.project.local"))
        return "text/x-cabal; charset=utf-8";

    // Terraform
    if (std.mem.eql(u8, filename, "main.tf") or
        std.mem.eql(u8, filename, "variables.tf") or
        std.mem.eql(u8, filename, "outputs.tf") or
        std.mem.eql(u8, filename, "terraform.tfvars"))
        return "text/x-terraform; charset=utf-8";

    // Nginx
    if (std.mem.eql(u8, filename, "nginx.conf"))
        return "text/x-nginx-conf; charset=utf-8";

    // Shell config
    if (std.mem.eql(u8, filename, ".bashrc") or
        std.mem.eql(u8, filename, ".bash_profile") or
        std.mem.eql(u8, filename, ".zshrc") or
        std.mem.eql(u8, filename, ".profile") or
        std.mem.eql(u8, filename, ".env") or
        std.mem.eql(u8, filename, ".env.example") or
        std.mem.eql(u8, filename, ".env.local") or
        std.mem.eql(u8, filename, ".env.production"))
        return "application/x-sh; charset=utf-8";

    // TOML config files
    if (std.mem.eql(u8, filename, ".rustfmt.toml") or
        std.mem.eql(u8, filename, "rustfmt.toml") or
        std.mem.eql(u8, filename, "clippy.toml") or
        std.mem.eql(u8, filename, ".clippy.toml") or
        std.mem.eql(u8, filename, "taplo.toml") or
        std.mem.eql(u8, filename, ".taplo.toml"))
        return "application/toml";

    // YAML config files
    if (std.mem.eql(u8, filename, ".clang-format") or
        std.mem.eql(u8, filename, ".clang-tidy"))
        return "application/yaml";

    // Extension-based detection
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
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".ts")) return "text/x-typescript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".tsx")) return "text/x-typescript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".jsx")) return "text/x-jsx; charset=utf-8";
    if (std.mem.eql(u8, ext, ".go")) return "text/x-go; charset=utf-8";
    if (std.mem.eql(u8, ext, ".rs")) return "text/x-rust; charset=utf-8";
    if (std.mem.eql(u8, ext, ".java")) return "text/x-java; charset=utf-8";
    if (std.mem.eql(u8, ext, ".c")) return "text/x-c; charset=utf-8";
    if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cxx")) return "text/x-c++; charset=utf-8";
    if (std.mem.eql(u8, ext, ".h")) return "text/x-c; charset=utf-8";
    if (std.mem.eql(u8, ext, ".hpp")) return "text/x-c++; charset=utf-8";
    if (std.mem.eql(u8, ext, ".swift")) return "text/x-swift; charset=utf-8";
    if (std.mem.eql(u8, ext, ".kt")) return "text/x-kotlin; charset=utf-8";
    if (std.mem.eql(u8, ext, ".php")) return "text/x-php; charset=utf-8";
    if (std.mem.eql(u8, ext, ".zig")) return "text/x-zig; charset=utf-8";
    if (std.mem.eql(u8, ext, ".vue")) return "text/x-vue; charset=utf-8";
    if (std.mem.eql(u8, ext, ".svelte")) return "text/x-svelte; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".scss") or std.mem.eql(u8, ext, ".sass")) return "text/x-scss; charset=utf-8";
    if (std.mem.eql(u8, ext, ".less")) return "text/x-less; charset=utf-8";
    if (std.mem.eql(u8, ext, ".sql")) return "text/x-sql; charset=utf-8";
    if (std.mem.eql(u8, ext, ".graphql") or std.mem.eql(u8, ext, ".gql")) return "text/x-graphql; charset=utf-8";
    if (std.mem.eql(u8, ext, ".xml")) return "text/xml; charset=utf-8";
    if (std.mem.eql(u8, ext, ".ini")) return "text/x-ini; charset=utf-8";
    if (std.mem.eql(u8, ext, ".dockerfile")) return "text/x-dockerfile; charset=utf-8";
    if (std.mem.eql(u8, ext, ".makefile") or std.mem.eql(u8, ext, ".mk")) return "text/x-makefile; charset=utf-8";
    if (std.mem.eql(u8, ext, ".cmake")) return "text/x-cmake; charset=utf-8";
    if (std.mem.eql(u8, ext, ".tf")) return "text/x-terraform; charset=utf-8";
    if (std.mem.eql(u8, ext, ".ex") or std.mem.eql(u8, ext, ".exs")) return "text/x-elixir; charset=utf-8";
    if (std.mem.eql(u8, ext, ".dart")) return "text/x-dart; charset=utf-8";
    if (std.mem.eql(u8, ext, ".erl") or std.mem.eql(u8, ext, ".hrl")) return "text/x-erlang; charset=utf-8";
    if (std.mem.eql(u8, ext, ".hs") or std.mem.eql(u8, ext, ".lhs")) return "text/x-haskell; charset=utf-8";
    if (std.mem.eql(u8, ext, ".lua")) return "text/x-lua; charset=utf-8";
    if (std.mem.eql(u8, ext, ".r") or std.mem.eql(u8, ext, ".R")) return "text/x-rsrc; charset=utf-8";
    if (std.mem.eql(u8, ext, ".pl") or std.mem.eql(u8, ext, ".pm")) return "text/x-perl; charset=utf-8";

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
