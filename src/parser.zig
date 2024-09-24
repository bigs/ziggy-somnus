const std = @import("std");
const testing = std.testing;
const mecha = @import("mecha");
const mascii = mecha.ascii;

pub const IrcMessageType = enum {
    privmsg,
    notice,
    join,
    part,
    quit,
    nick,
    mode,
    topic,
    kick,
    ping,
    pong,
};

pub const IrcServerMessage = union(IrcMessageType) {
    privmsg: struct {
        sender: []const u8,
        target: []const u8,
        message: []const u8,
    },
    notice: struct {
        sender: []const u8,
        target: []const u8,
        message: []const u8,
    },
    join: struct {
        channel: []const u8,
        user: []const u8,
    },
    part: struct {
        user: []const u8,
        channel: []const u8,
        reason: ?[]const u8,
    },
    quit: struct {
        user: []const u8,
        reason: ?[]const u8,
    },
    nick: struct {
        old_nick: []const u8,
        new_nick: []const u8,
    },
    mode: struct {
        user: []const u8,
        target: []const u8,
        mode: []const u8,
        params: ?[]const u8,
    },
    topic: struct {
        user: []const u8,
        channel: []const u8,
        topic: []const u8,
    },
    kick: struct {
        sender: []const u8,
        channel: []const u8,
        user: []const u8,
        reason: ?[]const u8,
    },
    ping: struct {
        server: []const u8,
    },
    pong: struct {
        server: []const u8,
    },
};

fn parse_symbolic(_: std.mem.Allocator, input: []const u8) mecha.Error!mecha.Result(u8) {
    if (input.len == 0) {
        return mecha.Error.ParserFailed;
    }

    const value = input[0];
    const rest = input[1..];

    if (!std.ascii.isPrint(value) or std.ascii.isWhitespace(value)) {
        return mecha.Error.ParserFailed;
    }

    return mecha.Result(u8){
        .value = value,
        .rest = rest,
    };
}

const symbolic = mecha.Parser(u8){ .parse = parse_symbolic };
const symbolic_string = mecha.many(symbolic, .{ .collect = false, .min = 1 });

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

test "fail" {
    try testing.expect(false);
}

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

const host: mecha.Parser([]const u8) = mecha.many(symbolic, .{ .min = 1, .collect = false });

pub const IrcUser = struct {
    nick: []const u8,
    user: []const u8,
    host: []const u8,

    pub fn to_string(self: IrcUser, alloc: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(alloc, self.nick.len + 1 + self.user.len + 1 + self.host.len);
        try buf.appendSlice(self.nick);
        try buf.append('!');
        try buf.appendSlice(self.user);
        try buf.append('@');
        try buf.appendSlice(self.host);

        return buf.toOwnedSlice();
    }
};

pub const irc_user = mecha.map(mecha.combine(.{
    nickname,
    mascii.char('!').discard(),
    user,
    mascii.char('@').discard(),
    host,
}), mecha.toStruct(IrcUser));

test "IrcUser" {
    {
        const alloc = testing.allocator;

        const input = "nick!user@host.com PRIVMSG";
        const result = try irc_user.parse(alloc, input);

        try testing.expectEqualStrings("nick", result.value.nick);
        try testing.expectEqualStrings("user", result.value.user);
        try testing.expectEqualStrings("host.com", result.value.host);

        const string = try result.value.to_string(alloc);
        defer alloc.free(string);
        try testing.expectEqualStrings("nick!user@host.com", string);
    }

    {
        const alloc = testing.allocator;

        const input = "nick!user";
        const result = irc_user.parse(alloc, input);
        try testing.expectError(mecha.Error.ParserFailed, result);
    }

    {
        const alloc = testing.allocator;

        const input = "nick!user@host.com PRIVMSG";
        const result = try irc_user.asStr().parse(alloc, input);
        try testing.expectEqualStrings("nick!user@host.com", result.value);
    }
}

fn ToStructResult(comptime T: type) type {
    return @TypeOf(struct {
        fn func(_: anytype) T {
            return undefined;
        }
    }.func);
}

fn enum_string_name(comptime t: anytype) []const u8 {
    const T = @TypeOf(t);
    const type_info = @typeInfo(T);

    // Ensure that T is an enum
    if (type_info != .Enum) @compileError("Function expects an enum type");

    inline for (type_info.Enum.fields) |field| {
        if (@field(T, field.name) == t) {
            return field.name;
        }
    }

    // This should never be reached if t is a valid enum value
    @compileError("Invalid enum value");
}

fn toTaggedStruct(comptime T: type, comptime index: anytype) ToStructResult(T) {
    return struct {
        fn func(tuple: anytype) T {
            const info = @typeInfo(T);
            const union_fields = info.Union.fields;
            const enum_name = comptime enum_string_name(index);

            inline for (union_fields) |field| {
                if (comptime std.mem.eql(u8, field.name, enum_name)) {
                    const sub_struct_info = @typeInfo(field.type);
                    const sub_struct_fields = sub_struct_info.Struct.fields;

                    if (sub_struct_fields.len != tuple.len)
                        @compileError(@typeName(T) ++ "(" ++ enum_name ++ ") and " ++ @typeName(@TypeOf(tuple)) ++ " does not have " ++
                            "same number of fields. Conversion is not possible.");

                    var sub_struct: field.type = undefined;

                    inline for (sub_struct_fields, 0..) |sub_field, i| {
                        @field(sub_struct, sub_field.name) = tuple[i];
                    }

                    return @unionInit(T, enum_name, sub_struct);
                }
            }

            @compileError("Failed to find enum in union type");
        }
    }.func;
}

test "toTaggedStruct" {
    const x: IrcServerMessage = toTaggedStruct(IrcServerMessage, IrcMessageType.privmsg)(.{ "nick!user@host.com", "#room", "sup jies" });

    try testing.expect(x == .privmsg);
    try testing.expectEqualStrings("nick!user@host.com", x.privmsg.sender);
    try testing.expectEqualStrings("#room", x.privmsg.target);
    try testing.expectEqualStrings("sup jies", x.privmsg.message);
}

const msg_target: mecha.Parser([]const u8) = mecha.many(symbolic, .{ .collect = false, .min = 1 });

fn parse_message(comptime msg_type: IrcMessageType) mecha.Parser(IrcServerMessage) {
    const msg_type_string = comptime enum_string_name(msg_type);
    var msg_type_caps: [msg_type_string.len]u8 = undefined;
    for (msg_type_string, 0..) |char, i| {
        msg_type_caps[i] = std.ascii.toUpper(char);
    }

    const parser = mecha.combine(.{
        mascii.char(':').discard(),
        irc_user.asStr(),
        mecha.string(" " ++ msg_type_caps ++ " ").discard(),
        msg_target,
        mecha.string(" :").discard(),
        mecha.many(mascii.not(mascii.control), .{ .collect = false, .min = 1 }),
        mecha.string("\r\n").discard(),
    });

    return parser.map(toTaggedStruct(IrcServerMessage, msg_type));
}

pub const privmsg = parse_message(IrcMessageType.privmsg);
pub const notice = parse_message(IrcMessageType.notice);

const parse_opt_message = mecha.combine(.{
    mecha.string(" :").discard(),
    mecha.many(mascii.not(mascii.control), .{ .collect = false, .min = 1 }),
}).opt();

pub const part = mecha.combine(.{
    mascii.char(':').discard(),
    irc_user.asStr(),
    mecha.string(" PART ").discard(),
    msg_target,
    parse_opt_message,
    mecha.string("\r\n").discard(),
}).map(toTaggedStruct(IrcServerMessage, IrcMessageType.part));

pub const quit = mecha.combine(.{
    mascii.char(':').discard(),
    irc_user.asStr(),
    mecha.string(" QUIT").discard(),
    parse_opt_message,
    mecha.string("\r\n").discard(),
}).map(toTaggedStruct(IrcServerMessage, IrcMessageType.quit));

pub const nick = mecha.combine(.{
    mascii.char(':').discard(),
    irc_user.asStr(),
    mecha.string(" NICK ").discard(),
    nickname,
    mecha.string("\r\n").discard(),
}).map(toTaggedStruct(IrcServerMessage, IrcMessageType.nick));

pub const mode = mecha.combine(.{
    mascii.char(':').discard(),
    irc_user.asStr(),
    mecha.string(" MODE ").discard(),
    msg_target,
    mecha.string(" ").discard(),
    symbolic_string,
    mecha.opt(mecha.combine(.{
        mecha.string(" ").discard(),
        mecha.many(mascii.not(mascii.control), .{ .collect = false, .min = 1 }),
    })),
    mecha.string("\r\n").discard(),
}).map(toTaggedStruct(IrcServerMessage, IrcMessageType.mode));

pub const topic = mecha.combine(.{
    mascii.char(':').discard(),
    irc_user.asStr(),
    mecha.string(" TOPIC ").discard(),
    msg_target,
    mecha.string(" :").discard(),
    mecha.many(mascii.not(mascii.control), .{ .collect = false, .min = 0 }),
    mecha.string("\r\n").discard(),
}).map(toTaggedStruct(IrcServerMessage, IrcMessageType.topic));

pub const kick = mecha.combine(.{
    mascii.char(':').discard(),
    irc_user.asStr(),
    mecha.string(" KICK ").discard(),
    msg_target,
    mecha.string(" ").discard(),
    nickname,
    parse_opt_message,
    mecha.string("\r\n").discard(),
}).map(toTaggedStruct(IrcServerMessage, IrcMessageType.kick));

pub const ping = mecha.combine(.{
    mecha.string("PING :").discard(),
    symbolic_string,
    mecha.string("\r\n").discard(),
}).map(struct {
    fn map(server: []const u8) IrcServerMessage {
        return IrcServerMessage{ .ping = .{ .server = server } };
    }
}.map);

pub const pong = mecha.combine(.{
    mecha.string("PONG ").discard(),
    symbolic_string,
    mecha.string("\r\n").discard(),
}).map(struct {
    fn map(server: []const u8) IrcServerMessage {
        return IrcServerMessage{ .pong = .{ .server = server } };
    }
}.map);

test "privmsg" {
    {
        const alloc = testing.allocator;

        const input = ":nick!user@host.com PRIVMSG #room :sup jies\r\n";
        const result = try privmsg.parse(alloc, input);

        try testing.expect(result.value == .privmsg);
        try testing.expectEqualStrings("nick!user@host.com", result.value.privmsg.sender);
        try testing.expectEqualStrings("#room", result.value.privmsg.target);
        try testing.expectEqualStrings("sup jies", result.value.privmsg.message);
    }

    {
        const alloc = testing.allocator;

        const input = ":nick!user@host.com PRIVMSG #room :sup jies";
        const result = privmsg.parse(alloc, input);
        try testing.expectError(mecha.Error.ParserFailed, result);
    }

    {
        const alloc = testing.allocator;

        const input = ":nick!user@host.com #room :sup jies\r\n";
        const result = privmsg.parse(alloc, input);
        try testing.expectError(mecha.Error.ParserFailed, result);
    }
}

test "part" {
    {
        const alloc = testing.allocator;

        const input = ":nick!user@host.com PART #room :test\r\n";
        const result = try part.parse(alloc, input);

        try testing.expect(result.value == .part);
        try testing.expectEqualStrings("nick!user@host.com", result.value.part.user);
        try testing.expectEqualStrings("#room", result.value.part.channel);
        const reason = result.value.part.reason orelse "fail";
        try testing.expect(std.mem.eql(u8, reason, "test"));
    }

    {
        const alloc = testing.allocator;

        const input = ":nick!user@host.com PART #room\r\n";
        const result = try part.parse(alloc, input);

        try testing.expect(result.value == .part);
        try testing.expectEqualStrings("nick!user@host.com", result.value.part.user);
        try testing.expectEqualStrings("#room", result.value.part.channel);
        try testing.expectEqual(null, result.value.part.reason);
    }
}

test "quit" {
    {
        const alloc = testing.allocator;

        const input = ":nick!user@host.com QUIT :test\r\n";
        const result = try quit.parse(alloc, input);

        try testing.expect(result.value == .quit);
        try testing.expectEqualStrings("nick!user@host.com", result.value.quit.user);
        const reason = result.value.quit.reason orelse "fail";
        try testing.expect(std.mem.eql(u8, reason, "test"));
    }

    {
        const alloc = testing.allocator;

        const input = ":nick!user@host.com QUIT\r\n";
        const result = try quit.parse(alloc, input);

        try testing.expect(result.value == .quit);
        try testing.expectEqualStrings("nick!user@host.com", result.value.quit.user);
        try testing.expectEqual(null, result.value.quit.reason);
    }
}

test "nick" {
    const alloc = testing.allocator;

    const input = ":oldnick!user@host.com NICK newnick\r\n";
    const result = try nick.parse(alloc, input);

    try testing.expect(result.value == .nick);
    try testing.expectEqualStrings("oldnick!user@host.com", result.value.nick.old_nick);
    try testing.expectEqualStrings("newnick", result.value.nick.new_nick);
}

test "mode" {
    const alloc = testing.allocator;

    // User mode
    {
        const input = ":nick!user@host.com MODE nick +i\r\n";
        const result = try mode.parse(alloc, input);

        try testing.expect(result.value == .mode);
        try testing.expectEqualStrings("nick!user@host.com", result.value.mode.user);
        try testing.expectEqualStrings("nick", result.value.mode.target);
        try testing.expectEqualStrings("+i", result.value.mode.mode);
        try testing.expectEqual(null, result.value.mode.params);
    }

    // Channel mode without params
    {
        const input = ":nick!user@host.com MODE #channel +m\r\n";
        const result = try mode.parse(alloc, input);

        try testing.expect(result.value == .mode);
        try testing.expectEqualStrings("nick!user@host.com", result.value.mode.user);
        try testing.expectEqualStrings("#channel", result.value.mode.target);
        try testing.expectEqualStrings("+m", result.value.mode.mode);
        try testing.expectEqual(null, result.value.mode.params);
    }

    // Channel mode with params
    {
        const input = ":nick!user@host.com MODE #channel +o othernick\r\n";
        const result = try mode.parse(alloc, input);

        try testing.expect(result.value == .mode);
        try testing.expectEqualStrings("nick!user@host.com", result.value.mode.user);
        try testing.expectEqualStrings("#channel", result.value.mode.target);
        try testing.expectEqualStrings("+o", result.value.mode.mode);
        try testing.expectEqualStrings("othernick", result.value.mode.params.?);
    }

    // Channel mode with mask
    {
        const input = ":nick!user@host.com MODE #channel +b *!*@*.example.com\r\n";
        const result = try mode.parse(alloc, input);

        try testing.expect(result.value == .mode);
        try testing.expectEqualStrings("nick!user@host.com", result.value.mode.user);
        try testing.expectEqualStrings("#channel", result.value.mode.target);
        try testing.expectEqualStrings("+b", result.value.mode.mode);
        try testing.expectEqualStrings("*!*@*.example.com", result.value.mode.params.?);
    }
}

test "topic" {
    const alloc = testing.allocator;

    const input = ":nick!user@host.com TOPIC #channel :New channel topic\r\n";
    const result = try topic.parse(alloc, input);

    try testing.expect(result.value == .topic);
    try testing.expectEqualStrings("nick!user@host.com", result.value.topic.user);
    try testing.expectEqualStrings("#channel", result.value.topic.channel);
    try testing.expectEqualStrings("New channel topic", result.value.topic.topic);
}

test "kick" {
    {
        const alloc = testing.allocator;

        const input = ":nick!user@host.com KICK #channel user :Reason for kick\r\n";
        const result = try kick.parse(alloc, input);

        try testing.expect(result.value == .kick);
        try testing.expectEqualStrings("nick!user@host.com", result.value.kick.sender);
        try testing.expectEqualStrings("#channel", result.value.kick.channel);
        try testing.expectEqualStrings("user", result.value.kick.user);
        try testing.expectEqualStrings("Reason for kick", result.value.kick.reason.?);
    }

    {
        const alloc = testing.allocator;

        const input = ":nick!user@host.com KICK #channel user\r\n";
        const result = try kick.parse(alloc, input);

        try testing.expect(result.value == .kick);
        try testing.expectEqualStrings("nick!user@host.com", result.value.kick.sender);
        try testing.expectEqualStrings("#channel", result.value.kick.channel);
        try testing.expectEqualStrings("user", result.value.kick.user);
        try testing.expectEqual(null, result.value.kick.reason);
    }
}

test "ping" {
    const alloc = testing.allocator;

    const input = "PING :server.example.com\r\n";
    const result = try ping.parse(alloc, input);

    try testing.expect(result.value == .ping);
    try testing.expectEqualStrings("server.example.com", result.value.ping.server);
}

test "pong" {
    const alloc = testing.allocator;

    const input = "PONG server.example.com\r\n";
    const result = try pong.parse(alloc, input);

    try testing.expect(result.value == .pong);
    try testing.expectEqualStrings("server.example.com", result.value.pong.server);
}
