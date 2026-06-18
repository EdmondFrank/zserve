const std = @import("std");
const Io = std.Io;

const params = @import("params.zig");
const ServerContext = @import("server_context.zig").ServerContext;
const handler = @import("handler.zig");
const ThreadPool = @import("thread_pool.zig").ThreadPool;

/// Wrapper function for handling connections in the thread pool
fn handleConnectionWrapper(ctx: handler.ConnectionContext) !void {
    handler.handleConnection(ctx) catch |err| {
        std.debug.print("Error handling connection: {s}\n", .{@errorName(err)});
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Parse command line arguments
    const args = params.parseArgs(allocator, io, init.minimal.args) catch |err| {
        // Help is not really an error, just exit cleanly
        if (err == error.HelpRequested) {
            return;
        }
        return err;
    };

    // If help was shown, just exit
    if (args.show_help) {
        return;
    }

    defer {
        allocator.free(args.root_path);
        args.root_dir.close(io);
    }

    // Create server context
    var server_ctx = ServerContext.init(allocator, args.root_dir);
    defer server_ctx.deinit();

    // Initialize thread pool for concurrent connection handling
    const num_workers = std.Thread.getCpuCount() catch 4;
    var thread_pool = try ThreadPool.init(allocator, io, num_workers);
    defer thread_pool.deinit();
    std.debug.print("Thread pool initialized with {d} workers\n", .{num_workers});

    // Parse address and create listener
    const address = try Io.net.IpAddress.parseIp4(args.host, args.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    // Register SIGINT/SIGTERM handlers so Ctrl+C triggers a graceful shutdown
    const SigHandler = struct {
        var ctx: *ServerContext = undefined;
        fn handle(sig: c_int) callconv(.c) void {
            std.debug.print("\nReceived signal {d}, initiating shutdown...\n", .{sig});
            ctx.requestShutdown();
        }
    };
    SigHandler.ctx = &server_ctx;
    const sig_action = std.posix.Sigaction{
        .handler = .{ .handler = @ptrCast(&SigHandler.handle) },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sig_action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sig_action, null);

    std.debug.print("Server listening on http://{s}:{d}\n", .{ args.host, args.port });
    std.debug.print("Serving from root directory: {s}\n", .{args.root_path});

    if (args.enable_terminal) {
        std.debug.print("\n⚠️  WARNING: Web terminal is ENABLED!\n", .{});
        std.debug.print("⚠️  Anyone with access to this server can execute arbitrary commands.\n", .{});
        std.debug.print("⚠️  Terminal available at: http://{s}:{d}/__terminal__\n\n", .{ args.host, args.port });
    }

    std.debug.print("Press Ctrl+C to shutdown\n", .{});

    // Timeout for individual client connections to prevent slow clients from hanging workers
    const timeout = std.posix.timeval{ .sec = 1, .usec = 0 };

    // Accept connections loop with poll-based timeout checking
    while (!server_ctx.isShutdownRequested()) {
        // Use poll() to check if there's a connection ready with timeout
        var poll_fds = [_]std.posix.pollfd{
            .{
                .fd = server.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        // Poll with 100ms timeout to check shutdown flag frequently
        _ = std.posix.poll(&poll_fds, 100) catch {
            if (server_ctx.isShutdownRequested()) break;
            continue;
        };

        // Check shutdown flag after poll
        if (server_ctx.isShutdownRequested()) break;

        // Check if there's actually a connection ready
        if (poll_fds[0].revents & std.posix.POLL.IN == 0) continue;

        const stream = server.accept(io) catch |err| {
            if (server_ctx.isShutdownRequested()) break;
            // Handle common errors
            if (err == error.WouldBlock or err == error.ConnectionAborted) continue;
            std.debug.print("Error accepting connection: {s}\n", .{@errorName(err)});
            continue;
        };

        // Set receive timeout on the connection to prevent indefinite blocking on reads
        // This prevents a slow/stalled client from hanging the server
        std.posix.setsockopt(
            stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch |err| {
            std.debug.print("Warning: Failed to set connection timeout: {s}\n", .{@errorName(err)});
        };

        // Also set send timeout to prevent hangs when writing responses to slow clients
        std.posix.setsockopt(
            stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&timeout),
        ) catch |err| {
            std.debug.print("Warning: Failed to set send timeout: {s}\n", .{@errorName(err)});
        };

        // Create connection context for the handler
        const conn_ctx = handler.ConnectionContext{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .root_dir = args.root_dir,
            .root_path = args.root_path,
            .enable_terminal = args.enable_terminal,
        };

        // Submit connection to thread pool for concurrent handling
        thread_pool.submit(handleConnectionWrapper, conn_ctx) catch |err| {
            std.debug.print("Error submitting connection to thread pool: {s}\n", .{@errorName(err)});
            stream.close(io);
        };
    }

    std.debug.print("\nShutting down...\n", .{});
}
