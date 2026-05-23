const std = @import("std");
const Io = std.Io;

pub const Task = struct {
    fn_ptr: *const fn (*anyopaque) anyerror!void,
    arg: *anyopaque,
};

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    io: Io,
    workers: std.ArrayList(std.Thread),
    task_queue: std.ArrayList(Task),
    queue_mutex: Io.Mutex,
    queue_cond: Io.Condition,
    shutdown: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: Io, num_workers: usize) !*Self {
        const pool = try allocator.create(Self);
        pool.* = .{
            .allocator = allocator,
            .io = io,
            .workers = try std.ArrayList(std.Thread).initCapacity(allocator, num_workers),
            .task_queue = try std.ArrayList(Task).initCapacity(allocator, 64),
            .queue_mutex = Io.Mutex.init,
            .queue_cond = Io.Condition.init,
            .shutdown = false,
        };

        // Spawn worker threads
        var i: usize = 0;
        while (i < num_workers) : (i += 1) {
            const thread = try std.Thread.spawn(.{}, workerLoop, .{pool});
            try pool.workers.append(allocator, thread);
        }

        return pool;
    }

    pub fn deinit(self: *Self) void {
        // Signal shutdown
        self.queue_mutex.lock(self.io) catch {};
        self.shutdown = true;
        self.queue_cond.broadcast(self.io);
        self.queue_mutex.unlock(self.io);

        // Detach all worker threads instead of joining them
        // This allows the main thread to exit immediately without blocking on stuck workers
        // Workers that are idle will exit cleanly when they check the shutdown flag
        // Workers that are stuck in long operations will be terminated by the OS when the process exits
        for (self.workers.items) |worker| {
            worker.detach();
        }

        // Clean up
        self.workers.deinit(self.allocator);
        self.task_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn submit(self: *Self, comptime func: anytype, arg: anytype) !void {
        const ArgType = @TypeOf(arg);
        const TaskArg = struct {
            arg: ArgType,
            pool: *Self,
        };

        const task_arg = try self.allocator.create(TaskArg);
        task_arg.* = .{
            .arg = arg,
            .pool = self,
        };

        const wrapper = struct {
            fn wrapper(ctx: *anyopaque) anyerror!void {
                const typed_ctx: *TaskArg = @ptrCast(@alignCast(ctx));
                defer typed_ctx.pool.allocator.destroy(typed_ctx);
                try @call(.auto, func, .{typed_ctx.arg});
            }
        };

        const task = Task{
            .fn_ptr = wrapper.wrapper,
            .arg = task_arg,
        };

        try self.queue_mutex.lock(self.io);
        try self.task_queue.append(self.allocator, task);
        self.queue_cond.signal(self.io);
        self.queue_mutex.unlock(self.io);
    }

    fn workerLoop(pool: *Self) void {
        while (true) {
            // Dequeue a task inside a scoped block so the mutex is released
            // before executing the task.
            const task = blk: {
                pool.queue_mutex.lock(pool.io) catch break :blk null;
                defer pool.queue_mutex.unlock(pool.io);

                // Wait for a task or shutdown signal
                while (pool.task_queue.items.len == 0 and !pool.shutdown) {
                    pool.queue_cond.wait(pool.io, &pool.queue_mutex) catch {};
                }

                if (pool.shutdown) return;
                if (pool.task_queue.items.len == 0) return;

                break :blk pool.task_queue.swapRemove(pool.task_queue.items.len - 1);
            };

            if (task) |t| {
                // Execute task outside the lock so other workers can dequeue concurrently
                t.fn_ptr(t.arg) catch |err| {
                    std.debug.print("Task error: {s}\n", .{@errorName(err)});
                };
            }
        }
    }
};
