const std = @import("std");
const mecha = @import("mecha");
const somnus = @import("ziggy-somnus");
const commands = @import("commands.zig");
const linebuffer = @import("line_buffer.zig");
const parser = somnus.parser;
const atomic = std.atomic;
const net = std.net;
const builtin = std.builtin;
const testing = std.testing;

const LineBufferRing = linebuffer.LineBufferRing;

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
                // Add an extra byte for the delimiter
                buf.len = @min(read.len + 1, 512);
                break;
            }
        } else {
            std.atomic.spinLoopHint();
        }
    }
}

fn register(allocator: std.mem.Allocator, writer: net.Stream.Writer, buffer_ring: *LineBufferRing(16)) !void {
    const nick_string = try commands.nick(allocator, "smns");
    std.debug.print("** Registering nick\n", .{});
    defer allocator.free(nick_string);
    try writer.writeAll(nick_string);
    const user_string = try commands.user(allocator, "smns", 0, "Somnus");
    std.debug.print("** Registering user\n", .{});
    defer allocator.free(user_string);
    try writer.writeAll(user_string);

    while (true) {
        if (buffer_ring.consume()) |buf| {
            defer buf.mut.unlock();
            const line = buf.buf[0..buf.len];
            const result: mecha.Result(parser.IrcServerMessage) = try parser.parse_irc_message.parse(allocator, line);
            switch (result.value) {
                .server => |server| {
                    std.debug.print("** Server ({d:0>3}): {s}\n", .{ server.code, server.message });
                    if (server.code == 1) break;
                },
                .notice => |notice| {
                    std.debug.print("** Notice from {s}: {s}\n", .{ notice.sender, notice.message });
                },
                else => |val| {
                    const tag = @tagName(val);
                    std.debug.print("Got tag {s}\n", .{tag});
                },
            }
        } else {
            std.atomic.spinLoopHint();
        }
    }
}

fn irc_loop(allocator: std.mem.Allocator, writer: net.Stream.Writer, buffer_ring: *LineBufferRing(16)) !void {
    try register(allocator, writer, buffer_ring);

    while (true) {
        if (buffer_ring.consume()) |buf| {
            defer buf.mut.unlock();
            const line = buf.buf[0..buf.len];
            const result = parser.parse_irc_message.parse(allocator, line) catch {
                std.debug.print("** Error parsing message:\n**** {s}\n", .{line});
                continue;
            };
            switch (result.value) {
                .notice => |notice| {
                    std.debug.print("** Notice received from {s} for {s}: {s}\n", .{ notice.sender, notice.target, notice.message });
                },
                .server => |server| {
                    std.debug.print("** Server ({d:0>3}): {s}\n", .{ server.code, server.message });
                },
                .ping => |ping| {
                    std.debug.print("** Ping? Pong!\n", .{});
                    const pong_message = try commands.pong(allocator, ping.message);
                    try writer.writeAll(pong_message);
                },
                else => {
                    std.debug.print("** Got some other message\n", .{});
                },
            }
        } else {
            std.atomic.spinLoopHint();
        }
    }
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
    try irc_loop(allocator, stream.writer(), buffer_ring);
    read_thread.join();
}
