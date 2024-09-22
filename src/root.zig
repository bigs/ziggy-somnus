const std = @import("std");
const testing = std.testing;
const mecha = @import("mecha");
const mascii = mecha.ascii;

pub const IrcMessageType = enum {
    PRIVMSG,
    NOTICE,
    JOIN,
    PART,
    QUIT,
    NICK,
    MODE,
    TOPIC,
    KICK,
    PING,
    PONG,
};

pub const IrcMessage = union(IrcMessageType) {
    PRIVMSG: struct {
        sender: []const u8,
        target: []const u8,
        message: []const u8,
    },
    NOTICE: struct {
        sender: []const u8,
        target: []const u8,
        message: []const u8,
    },
    JOIN: struct {
        channel: []const u8,
        user: []const u8,
    },
    PART: struct {
        channel: []const u8,
        user: []const u8,
        reason: ?[]const u8,
    },
    QUIT: struct {
        user: []const u8,
        reason: ?[]const u8,
    },
    NICK: struct {
        old_nick: []const u8,
        new_nick: []const u8,
    },
    MODE: struct {
        target: []const u8,
        mode: []const u8,
        params: ?[]const u8,
    },
    TOPIC: struct {
        channel: []const u8,
        topic: []const u8,
    },
    KICK: struct {
        channel: []const u8,
        user: []const u8,
        reason: ?[]const u8,
    },
    PING: struct {
        server: []const u8,
    },
    PONG: struct {
        server: []const u8,
    },
};

const nickname_symbols: mecha.Parser(u8) = mecha.oneOf(.{
    mascii.char('['),
    mascii.char(']'),
    mascii.char('/'),
    mascii.char('`'),
    mascii.char('_'),
    mascii.char('^'),
    mascii.char('{'),
    mascii.char('|'),
    mascii.char('}'),
});

const nickname_char: mecha.Parser(u8) = mecha.oneOf(.{
    nickname_symbols,
    mascii.alphanumeric,
});

const nickname_first_char: mecha.Parser([]u8) = mecha.many(mecha.oneOf(.{ mascii.alphabetic, nickname_symbols }), .{ .min = 1, .max = 1 });
const nickname_chars: mecha.Parser([]u8) = mecha.many(nickname_char, .{ .max = 8 });

fn parse_nickname_zc(_: std.mem.Allocator, input: []const u8) mecha.Error!mecha.Result([]const u8) {
    const symbols = &[_]u8{ '[', ']', '/', '`', '_', '^', '{', '|', '}' };
    var index: usize = 0;
    const max_index = 8;

    if (input.len == 0 or !(std.ascii.isAlphabetic(input[0]) == true or std.mem.indexOf(u8, symbols, input[0..1]) != null)) {
        return mecha.Error.ParserFailed;
    }

    for (input[1..], 1..) |_, _index| {
        if (index < max_index and (std.ascii.isAlphanumeric(input[_index]) or std.mem.indexOf(u8, symbols, input[_index .. _index + 1]) != null)) {
            index = _index;
        } else {
            break;
        }
    }

    index += 1;
    const value = input[0..index];
    const rest = input[index..];

    return mecha.Result([]const u8){
        .rest = rest,
        .value = value,
    };
}

const nickname: mecha.Parser([]const u8) = .{ .parse = parse_nickname_zc };

test "nickname" {
    const alloc = testing.allocator;
    var result = try nickname.parse(alloc, "foobar");

    try testing.expectEqualStrings("foobar", result.value);

    result = try nickname.parse(alloc, "a123456789");
    try testing.expectEqualStrings("a12345678", result.value);

    const res = nickname.parse(alloc, "1234");
    try testing.expectError(mecha.Error.ParserFailed, res);

    result = try nickname.parse(alloc, "foobar!bar@user.com");
    try testing.expectEqualStrings("foobar", result.value);

    result = try nickname.parse(alloc, "f");
    try testing.expectEqualStrings("f", result.value);
}

const user_symbols = mascii.not(mecha.oneOf(.{
    mascii.char('\r'),
    mascii.char('\n'),
    mascii.char(' '),
    mascii.char('@'),
}));

const user: mecha.Parser([]const u8) = mecha.many(user_symbols, .{ .min = 1, .collect = false });

test "user" {
    const alloc = testing.allocator;

    var result = try user.parse(alloc, "foobar");
    try testing.expectEqualStrings("foobar", result.value);

    result = try user.parse(alloc, "foo@bar");
    try testing.expectEqualStrings("foo", result.value);
}

const host_symbols: mecha.Parser(u8) = mascii.not(mascii.whitespace);
const host: mecha.Parser([]const u8) = mecha.many(host_symbols, .{ .min = 1, .collect = false });

pub const IrcUser = struct {
    nick: []const u8,
    user: []const u8,
    host: []const u8,
};

pub const irc_user = mecha.map(mecha.combine(.{
    nickname,
    mascii.char('!').discard(),
    user,
    mascii.char('@').discard(),
    host,
}), mecha.toStruct(IrcUser));

pub const Delim = mecha.string("\r\n");

test "IrcUser" {
    {
        const alloc = testing.allocator;

        const input = "nick!user@host.com PRIVMSG";
        const result = try irc_user.parse(alloc, input);

        try testing.expectEqualStrings("nick", result.value.nick);
        try testing.expectEqualStrings("user", result.value.user);
        try testing.expectEqualStrings("host.com", result.value.host);
    }

    {
        const alloc = testing.allocator;

        const input = "nick!user";
        const result = irc_user.parse(alloc, input);
        try testing.expectError(mecha.Error.ParserFailed, result);
    }
}
