const std = @import("std");

pub fn nick(allocator: std.mem.Allocator, nickname: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "NICK {s}\r\n", .{nickname});
}

pub fn user(allocator: std.mem.Allocator, nickname: []const u8, mode: u8, realname: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "USER {s} {d} * :{s}\r\n", .{ nickname, mode, realname });
}

pub fn pong(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "PONG :{s}\r\n", .{message});
}

pub fn join(allocator: std.mem.Allocator, channel: []const u8, password: ?[]const u8) ![]const u8 {
    if (password) |pass| {
        return std.fmt.allocPrint(allocator, "JOIN {s} {s}\r\n", .{ channel, pass });
    } else {
        return std.fmt.allocPrint(allocator, "JOIN {s}\r\n", .{channel});
    }
}
