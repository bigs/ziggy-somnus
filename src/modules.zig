const std = @import("std");
const mecha = @import("mecha");
const parser = @import("ziggy-somnus").parser;
const commands = @import("commands.zig");

pub const Module = struct {
    ptr: *const anyopaque,
    impl: *const Interface,

    pub const Interface = struct {
        process_message: *const fn (self: *const anyopaque, msg: *const parser.IrcServerMessage, writer: *const std.net.Stream.Writer) void,
    };

    pub fn process_message(self: Module, msg: *const parser.IrcServerMessage, writer: *const std.net.Stream.Writer) void {
        return self.impl.process_message(self.ptr, msg, writer);
    }
};

pub const PingModule = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PingModule {
        return .{ .allocator = allocator };
    }

    pub fn create(self: *PingModule) Module {
        return .{
            .ptr = self,
            .impl = &.{ .process_message = process_message },
        };
    }

    fn process_message(ctx: *const anyopaque, msg: *const parser.IrcServerMessage, writer: *const std.net.Stream.Writer) void {
        const self: *const PingModule = @ptrCast(@alignCast(ctx));

        if (msg.* == .ping) {
            const message = commands.pong(self.allocator, msg.ping.message) catch @panic("PingModule, create message");
            writer.writeAll(message) catch @panic("PingModule, write message");
            std.debug.print("** [PingModule] Ping? Pong!\n", .{});
        }
    }
};

pub const JoinModule = struct {
    allocator: std.mem.Allocator,
    admin: []const u8,

    const command_parser = mecha.combine(.{
        mecha.string("!join ").discard(),
        mecha.combine(.{
            mecha.ascii.char('#'),
            mecha.many(mecha.ascii.not(mecha.ascii.whitespace), .{ .collect = false, .min = 1 }),
        }).asStr(),
    });

    pub fn init(allocator: std.mem.Allocator, admin: []const u8) JoinModule {
        return .{ .allocator = allocator, .admin = admin };
    }

    pub fn create(self: *JoinModule) Module {
        return .{
            .ptr = self,
            .impl = &.{ .process_message = process_message },
        };
    }

    fn process_message(ctx: *const anyopaque, msg: *const parser.IrcServerMessage, writer: *const std.net.Stream.Writer) void {
        const self: *const JoinModule = @ptrCast(@alignCast(ctx));

        if (msg.* == .privmsg) {
            const privmsg = msg.privmsg;
            const user_result = parser.irc_user.parse(self.allocator, privmsg.sender) catch return;
            const user: parser.IrcUser = user_result.value;
            if (!std.mem.eql(u8, user.nick, self.admin)) {
                return;
            }

            const result = command_parser.parse(self.allocator, privmsg.message) catch |err| switch (err) {
                mecha.Error.ParserFailed => return,
                else => {
                    std.debug.print("Error in JoinModule: {}", .{err});
                    return;
                },
            };

            const message = commands.join(self.allocator, result.value, null) catch @panic("JoinModule, creating message");

            writer.writeAll(message) catch @panic("JoinModule, write message");
            std.debug.print("** [JoinModule] Joined {s} on command from {s}\n", .{ result.value, self.admin });
        }
    }
};
