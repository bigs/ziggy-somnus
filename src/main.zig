const std = @import("std");
const mecha = @import("mecha");
const somnus = @import("ziggy-somnus");
const atomic = std.atomic;
const net = std.net;
const builtin = std.builtin;
const testing = std.testing;

fn LineBuffer(comptime n: usize) type {
    return struct { buf: [n]u8 = undefined, len: usize = 0, mut: std.Thread.Mutex = .{} };
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
            if (!self.bufs[tail].mut.tryLock()) {
                return null;
            }
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

fn read_loop(reader: net.Stream.Reader, buffer_ring: *LineBufferRing(16)) !void {
    while (true) {
        if (buffer_ring.acquire()) |buf| {
            defer buf.mut.unlock();
            while (true) {
                const result = reader.readUntilDelimiter(&buf.buf, '\n');
                const read = result catch |err| switch (err) {
                    error.StreamTooLong => continue,
                    else => return err,
                };
                buf.len = read.len;
                break;
            }
        } else {
            std.atomic.spinLoopHint();
        }
    }
}

const Args = struct {
    host: []const u8,
    port: u16,
};

const Error = error{InvalidArgs};

const ParseArgsError = Error || std.fmt.ParseIntError || std.process.ArgIterator.InitError;

fn parse_args(allocator: std.mem.Allocator) ParseArgsError!Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    if (!args.skip()) {
        return Error.InvalidArgs;
    }

    const host = args.next() orelse return Error.InvalidArgs;
    const port_string = args.next() orelse return Error.InvalidArgs;
    const port = try std.fmt.parseUnsigned(u16, port_string, 10);

    return Args{ .host = host, .port = port };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator: std.mem.Allocator = gpa.allocator();
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            @panic("Memory leak");
        }
    }
    const spawn_config = std.Thread.SpawnConfig{ .allocator = allocator };
    const buffer_ring = try LineBufferRing(16).init(allocator);
    defer buffer_ring.deinit();

    const args = try parse_args(allocator);
    const stream = try net.tcpConnectToHost(allocator, args.host, args.port);
    const read_thread = try std.Thread.spawn(spawn_config, read_loop, .{ stream.reader(), buffer_ring });
    while (true) {
        if (buffer_ring.consume()) |buf| {
            defer buf.mut.unlock();
            const line = buf.buf[0 .. buf.len - 1];
            std.debug.print("**** {s}\n", .{line});
        } else {
            std.atomic.spinLoopHint();
        }
    }
    read_thread.join();
}
