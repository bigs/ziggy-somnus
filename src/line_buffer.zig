const std = @import("std");
const atomic = std.atomic;
const testing = std.testing;

pub fn LineBuffer(comptime n: usize) type {
    return struct { buf: [n]u8 = undefined, len: usize = 0, mut: std.Thread.Mutex = .{} };
}

// SPSC Ring Buffer
pub fn LineBufferRing(comptime n: usize) type {
    return struct {
        const Self = @This();

        bufs: [n]LineBuffer(512),
        head: atomic.Value(u8),
        tail: atomic.Value(u8),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const line_buffer_ring = try allocator.create(Self);
            for (&line_buffer_ring.bufs) |*buf| {
                buf.* = .{};
            }
            line_buffer_ring.head = atomic.Value(u8).init(0);
            line_buffer_ring.tail = atomic.Value(u8).init(0);
            line_buffer_ring.allocator = allocator;

            return line_buffer_ring;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        pub fn acquire(self: *Self) ?*LineBuffer(512) {
            const tail = self.tail.load(.acquire);
            const next = (tail + 1) % @as(u8, n);
            if (next == self.head.load(.acquire)) {
                return null;
            }
            if (!self.bufs[tail].mut.tryLock()) {
                return null;
            }
            if (self.tail.cmpxchgStrong(tail, next, .acq_rel, .acquire)) |_| {
                self.bufs[tail].mut.unlock();
                return null;
            }
            return &self.bufs[tail];
        }

        pub fn consume(self: *Self) ?*LineBuffer(512) {
            const head = self.head.load(.acquire);
            if (head == self.tail.load(.acquire)) {
                return null;
            }
            const next = (head + 1) % @as(u8, n);
            if (!self.bufs[head].mut.tryLock()) {
                return null;
            }
            if (self.head.cmpxchgStrong(head, next, .acq_rel, .acquire)) |_| {
                self.bufs[head].mut.unlock();
                return null;
            }
            return &self.bufs[head];
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
