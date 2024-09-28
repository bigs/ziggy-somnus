const std = @import("std");
const atomic = std.atomic;
const testing = std.testing;

pub fn LineBuffer(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,
        mut: std.Thread.Mutex = .{},
    };
}

/// SPSC Ring Buffer. Prone to deadlocks if there are multiple consumers or
/// producers.
pub fn LineBufferRing(comptime n: usize) type {
    return struct {
        const Self = @This();

        bufs: [n]LineBuffer(512),
        head: u8,
        tail: u8,

        not_full: std.Thread.Condition,
        not_empty: std.Thread.Condition,
        mutex: std.Thread.Mutex,

        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const line_buffer_ring = try allocator.create(Self);
            for (&line_buffer_ring.bufs) |*buf| {
                buf.* = .{};
            }
            line_buffer_ring.head = 0;
            line_buffer_ring.tail = 0;
            line_buffer_ring.not_empty = .{};
            line_buffer_ring.not_full = .{};
            line_buffer_ring.mutex = .{};
            line_buffer_ring.allocator = allocator;

            return line_buffer_ring;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        pub fn acquire(self: *Self) *LineBuffer(512) {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                const next = (self.tail + 1) % @as(u8, n);
                if (next != self.head) {
                    self.tail = next;
                    self.bufs[self.tail].mut.lock();
                    self.not_empty.signal();
                    return &self.bufs[self.tail];
                }
                self.not_full.wait(&self.mutex);
            }
        }

        pub fn consume(self: *Self) *LineBuffer(512) {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (true) {
                if (self.head != self.tail) {
                    const next = (self.head + 1) % @as(u8, n);
                    self.head = next;
                    self.bufs[self.head].mut.lock();
                    self.not_full.signal();
                    return &self.bufs[self.head];
                }
                self.not_empty.wait(&self.mutex);
            }
        }
    };
}

test "LineBuffer" {
    const allocator = testing.allocator;
    const line_buffer_ring = try LineBufferRing(16).init(allocator);
    defer line_buffer_ring.deinit();

    try testing.expectEqual(null, line_buffer_ring.consume());

    const buf = line_buffer_ring.acquire();
    try testing.expect(buf != null);
    try testing.expectEqual(false, buf.?.mut.tryLock());
}
