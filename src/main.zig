const std = @import("std");
const mecha = @import("mecha");
const somnus = @import("ziggy-somnus");
const atomic = std.atomic;
const net = std.net;
const builtin = std.builtin;
const testing = std.testing;

fn LineBuffer(comptime n: usize) type {
    return struct { buf: [n]u8 = undefined, len: u16 = 0, mut: std.Thread.Mutex = .{} };
}

// SPSC Ring Buffer
fn LineBufferRing(comptime n: usize) type {
    return struct {
        const Self = @This();

        bufs: [n]LineBuffer(512),
        head: atomic.Value(u8),
        tail: atomic.Value(u8),
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) !*Self {
            const line_buffer_ring = try allocator.create(Self);
            for (&line_buffer_ring.bufs) |*buf| {
                buf.* = .{};
            }
            line_buffer_ring.head = atomic.Value(u8).init(0);
            line_buffer_ring.tail = atomic.Value(u8).init(0);
            line_buffer_ring.allocator = allocator;

            return line_buffer_ring;
        }

        fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        fn acquire(self: *Self) ?*LineBuffer(512) {
            const tail = self.tail.load(.acquire);
            const next = (tail + 1) % @as(u8, n);
            if (next == self.head.load(.acquire)) {
                return null;
            }
            self.bufs[tail].mut.lock();
            if (self.tail.cmpxchgStrong(tail, next, .acq_rel, .acquire)) |_| {
                self.bufs[tail].mut.unlock();
                return null;
            }
            return &self.bufs[tail];
        }

        fn consume(self: *Self) ?*LineBuffer(512) {
            const head = self.head.load(.acquire);
            if (head == self.tail.load(.acquire)) {
                return null;
            }
            const next = (head + 1) % @as(u8, n);
            self.bufs[head].mut.lock();
            self.head.store(next, .release);
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

// fn read_loop(allocator: std.mem.Allocator, reader: net.Stream.Reader) !void {
//     var buf: [512]u8 = undefined;

//     while (true) {
//         reader.readUntilDelimiter(buf: []u8, delimiter: u8)
//         reader.streamUntilDelimiter(buf, '\n', 512);
//     }
// }

pub fn main() !void {
    const gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer gpa.deinit();
    const allocator = gpa.allocator();
    // const spawn_config = std.Thread.SpawnConfig{ .allocator = allocator };

    const stream = try net.tcpConnectToHost(allocator, "faceroar.ijkl.me", 6667);
    stream.close();
    // const read_thread = try std.Thread.spawn(spawn_config, read_loop, .{ allocator, stream.reader() });
}
