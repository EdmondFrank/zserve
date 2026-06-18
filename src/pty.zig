const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const c = std.c;

/// Result of spawning a PTY child process
pub const PtyProcess = struct {
    master_fd: std.posix.fd_t,
    child_pid: std.posix.pid_t,

    /// Write data to the PTY (sent to the child's stdin)
    pub fn write(self: PtyProcess, data: []const u8) !usize {
        const n = c.write(self.master_fd, data.ptr, data.len);
        if (n < 0) return error.WriteFailed;
        return @intCast(n);
    }

    /// Read data from the PTY (child's stdout/stderr)
    pub fn read(self: PtyProcess, buf: []u8) !usize {
        const n = c.read(self.master_fd, buf.ptr, buf.len);
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }

    /// Resize the PTY window
    pub fn resize(self: PtyProcess, cols: u16, rows: u16) !void {
        const ws: extern struct {
            ws_row: u16,
            ws_col: u16,
            ws_xpixel: u16,
            ws_ypixel: u16,
        } = .{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        // TIOCSWINSZ: Linux = 0x5414, macOS = 0x80087467
        const TIOCSWINSZ: u32 = if (builtin.os.tag == .macos) 0x80087467 else 0x5414;
        const req_signed: c_int = @bitCast(TIOCSWINSZ);
        _ = std.posix.system.ioctl(self.master_fd, req_signed, @intFromPtr(&ws));
    }

    /// Kill the child process and close the master fd
    pub fn kill(self: PtyProcess) void {
        std.posix.kill(self.child_pid, std.posix.SIG.TERM) catch {};
        _ = c.close(self.master_fd);
    }
};

const native_os = builtin.os.tag;

// C library function declarations for PTY management
extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
extern "c" fn setsid() c_int;
extern "c" fn login_tty(fd: c_int) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;

// O_RDWR = 0x2, O_NOCTTY = 0x200000 on macOS, 0x100 on Linux
const O_RDWR: c_int = 0x2;
const O_NOCTTY: c_int = if (native_os == .macos) 0x200000 else 0x100;

/// Spawn a child process with a PTY.
/// The child runs the user's shell ($SHELL or default) with cwd set to `cwd`.
/// Returns the master_fd and child_pid.
pub fn spawn(cwd: []const u8) !PtyProcess {
    // Open a new pseudo-terminal master
    const master_fd_c = posix_openpt(O_RDWR | O_NOCTTY);
    if (master_fd_c < 0) {
        std.debug.print("posix_openpt failed\n", .{});
        return error.OpenPtyFailed;
    }
    const master_fd: std.posix.fd_t = @intCast(master_fd_c);

    // Grant and unlock the slave PTY
    if (grantpt(master_fd) != 0) {
        _ = c.close(master_fd);
        return error.GrantPtFailed;
    }
    if (unlockpt(master_fd) != 0) {
        _ = c.close(master_fd);
        return error.UnlockPtFailed;
    }

    // Set initial window size
    const WinSize = extern struct {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    };
    const ws: WinSize = .{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    const TIOCSWINSZ: u32 = if (native_os == .macos) 0x80087467 else 0x5414;
    const req_signed: c_int = @bitCast(TIOCSWINSZ);
    _ = std.posix.system.ioctl(master_fd, req_signed, @intFromPtr(&ws));

    // Fork the process
    const pid_c = c.fork();
    if (pid_c < 0) {
        _ = c.close(master_fd);
        return error.ForkFailed;
    }
    const pid: std.posix.pid_t = @intCast(pid_c);

    if (pid == 0) {
        // === CHILD PROCESS ===
        _ = setsid();

        // Get the slave PTY name
        const slave_name = ptsname(master_fd) orelse c.exit(1);

        // Open the slave PTY (with controlling terminal)
        const slave_fd_c = openSlave(slave_name);
        if (slave_fd_c < 0) c.exit(1);

        // Close the master in the child
        _ = c.close(master_fd);

        // login_tty sets up the slave as stdin/stdout/stderr and controlling terminal
        if (login_tty(slave_fd_c) != 0) {
            c.exit(1);
        }

        // Change working directory
        if (cwd.len > 0 and cwd.len < 4096) {
            var cwd_buf: [4096]u8 = undefined;
            @memcpy(cwd_buf[0..cwd.len], cwd);
            cwd_buf[cwd.len] = 0;
            _ = c.chdir(@ptrCast(&cwd_buf));
        }

        // Determine shell
        const shell_ptr = c.getenv("SHELL");
        var shell_buf: [4096]u8 = undefined;
        const shell: []const u8 = blk: {
            if (shell_ptr) |sp| {
                const s = std.mem.sliceTo(sp, 0);
                if (s.len > 0 and s.len < shell_buf.len) {
                    break :blk s;
                }
            }
            break :blk switch (native_os) {
                .macos => "/bin/zsh",
                else => "/bin/sh",
            };
        };

        // Build argv: [shell, "-l" (login shell)]
        @memcpy(shell_buf[0..shell.len], shell);
        shell_buf[shell.len] = 0;

        var argv: [3]?[*:0]u8 = .{ @ptrCast(&shell_buf), @ptrCast(@constCast("-l")), null };

        // Set TERM environment variable
        _ = setenv("TERM", "xterm-256color", 1);

        // Execute the shell
        _ = c.execve(@ptrCast(&shell_buf), @ptrCast(&argv), @ptrCast(c.environ));

        // If execve fails, exit
        c.exit(1);
    }

    // === PARENT PROCESS ===
    return PtyProcess{
        .master_fd = master_fd,
        .child_pid = pid,
    };
}

/// Open the slave PTY device with O_RDWR and controlling terminal
fn openSlave(name: [*:0]const u8) c_int {
    return open(name, O_RDWR);
}
