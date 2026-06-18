const std = @import("std");
const Io = std.Io;

const Args = struct {
    root_path: []u8,
    root_dir: Io.Dir,
    port: u16,
    host: []const u8,
    show_help: bool,
    enable_terminal: bool,
};

/// Print help message
fn printHelp(exe_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} [OPTIONS]
        \\
        \\Options:
        \\  --root PATH          Root directory to serve (required)
        \\  --port PORT, -p PORT Port to listen on (default: 8080)
        \\  --host HOST, -H HOST Host to bind to (default: 127.0.0.1)
        \\  --terminal           Enable web terminal (WARNING: grants shell access)
        \\  --help, -h           Show this help message
        \\
        \\Examples:
        \\  {s} --root /var/www
        \\  {s} --root . --port 9000
        \\  {s} --root /home/user/files --host 0.0.0.0 --port 8080
        \\
    , .{ exe_name, exe_name, exe_name, exe_name });
}

/// Parse command line arguments and return a struct containing the arguments
pub fn parseArgs(allocator: std.mem.Allocator, io: Io, process_args: std.process.Args) !Args {
    var args_iter = try process_args.iterateAllocator(allocator);
    defer args_iter.deinit();

    // Get executable name for help message
    const exe_name = args_iter.next() orelse "zserve";

    var root_path: []u8 = "";
    var root_dir: Io.Dir = undefined;
    var port: u16 = 8080;
    var host: []const u8 = "127.0.0.1";
    var show_help = false;
    var enable_terminal = false;

    // Parse arguments
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--root") or std.mem.eql(u8, arg, "-root")) {
            const path = args_iter.next() orelse {
                std.debug.print("Error: --root requires a path argument\n\n", .{});
                printHelp(exe_name);
                return error.InvalidArgument;
            };
            root_path = try allocator.dupe(u8, path);
            
            // Check if path is absolute, if not make it absolute
            if (std.fs.path.isAbsolute(root_path)) {
                root_dir = Io.Dir.openDirAbsolute(io, root_path, .{
                    .access_sub_paths = true,
                    .iterate = true,
                }) catch |err| {
                    std.debug.print("Error: Cannot open directory '{s}': {s}\n\n", .{ root_path, @errorName(err) });
                    printHelp(exe_name);
                    return error.InvalidArgument;
                };
            } else {
                // For relative paths, open relative to current working directory
                const cwd = Io.Dir.cwd();
                root_dir = cwd.openDir(io, root_path, .{
                    .access_sub_paths = true,
                    .iterate = true,
                }) catch |err| {
                    std.debug.print("Error: Cannot open directory '{s}': {s}\n\n", .{ root_path, @errorName(err) });
                    printHelp(exe_name);
                    return error.InvalidArgument;
                };
            }
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            const port_str = args_iter.next() orelse {
                std.debug.print("Error: --port requires a port number\n\n", .{});
                printHelp(exe_name);
                return error.InvalidArgument;
            };
            port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("Error: Invalid port number: {s}\n\n", .{port_str});
                printHelp(exe_name);
                return error.InvalidArgument;
            };
            if (port == 0) {
                std.debug.print("Error: Port must be between 1 and 65535\n\n", .{});
                printHelp(exe_name);
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "-H")) {
            const host_arg = args_iter.next() orelse {
                std.debug.print("Error: --host requires a host address\n\n", .{});
                printHelp(exe_name);
                return error.InvalidArgument;
            };
            host = try allocator.dupe(u8, host_arg);
        } else if (std.mem.eql(u8, arg, "--terminal")) {
            enable_terminal = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp(exe_name);
            show_help = true;
        } else {
            std.debug.print("Error: Unknown option: {s}\n\n", .{arg});
            printHelp(exe_name);
            return error.InvalidArgument;
        }
    }

    // Show help if requested
    if (show_help) {
        return Args{
            .root_path = "",
            .root_dir = undefined,
            .port = port,
            .host = host,
            .show_help = true,
            .enable_terminal = false,
        };
    }

    // Validate required arguments
    if (root_path.len == 0) {
        std.debug.print("Error: --root is required\n\n", .{});
        printHelp(exe_name);
        return error.InvalidArgument;
    }

    return Args{
        .root_path = root_path,
        .root_dir = root_dir,
        .port = port,
        .host = host,
        .show_help = false,
        .enable_terminal = enable_terminal,
    };
}
