const std = @import("std");

pub const Task = struct {
    fn_ptr: *const fn (*anyopaque) anyerror!void,
    arg: *anyopaque,
};

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    workers: std.ArrayList(std.Thread),
    task_queue: std.ArrayList(Task),
    queue_mutex: std.Thread.Mutex,
    queue_cond: std.Thread.Condition,
    shutdown: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !*Self {
        const pool = try allocator.create(Self);
        pool.* = .{
            .allocator = allocator,
            .workers = std.ArrayList(std.Thread).init(allocator),
            .task_queue = std.ArrayList(Task).init(allocator),
            .queue_mutex = .{},
            .queue_cond = .{},
            .shutdown = false,
        };

        // Spawn worker threads
        var i: usize = 0;
        while (i < num_workers) : (i += 1) {
            const thread = try std.Thread.spawn(.{}, workerLoop, .{pool});
            try pool.workers.append(thread);
        }

        return pool;
    }

    pub fn deinit(self: *Self) void {
        // Signal shutdown
        self.queue_mutex.lock();
        self.shutdown = true;
        self.queue_cond.broadcast();
        self.queue_mutex.unlock();

        // Wait for all workers to finish
        for (self.workers.items) |worker| {
            worker.join();
        }

        // Clean up
        self.workers.deinit();
        self.task_queue.deinit();
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

        self.queue_mutex.lock();
        try self.task_queue.append(task);
        self.queue_cond.signal();
        self.queue_mutex.unlock();
    }

    fn workerLoop(pool: *Self) void {
        while (true) {
            // Dequeue a task inside a scoped block so the mutex is released
            // before executing the task. This avoids the previous double-unlock
            // bug where a `defer unlock` and an explicit `unlock` both fired.
            const task = blk: {
                pool.queue_mutex.lock();
                defer pool.queue_mutex.unlock();

                // Wait for a task or shutdown signal
                while (pool.task_queue.items.len == 0 and !pool.shutdown) {
                    pool.queue_cond.wait(&pool.queue_mutex);
                }

                if (pool.shutdown) return;

                break :blk pool.task_queue.orderedRemove(0);
            }; // mutex is unlocked here by the deferred unlock above

            // Execute task outside the lock so other workers can dequeue concurrently
            task.fn_ptr(task.arg) catch |err| {
                std.debug.print("Task error: {s}\n", .{@errorName(err)});
            };
        }
    }
};
