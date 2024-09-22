const std = @import("std");
const testing = std.testing;
const mecha = @import("mecha");
const mascii = mecha.ascii;

pub fn parse_symbolic(_: std.mem.Allocator, input: []const u8) mecha.Error!mecha.Result(u8) {
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

pub const symbolic = mecha.Parser(u8){ .parse = parse_symbolic };
pub const symbolic_string = mecha.many(symbolic, .{ .collect = false, .min = 1 });

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
        channel: []const u8,
        user: []const u8,
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
        target: []const u8,
        mode: []const u8,
        params: ?[]const u8,
    },
    topic: struct {
        channel: []const u8,
        topic: []const u8,
    },
    kick: struct {
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

pub const Delim = mecha.string("\r\n");

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
    try testing.expectEqualStrings("#room", x.privmsg.target);
}

pub const msg_target: mecha.Parser([]const u8) = mecha.many(symbolic, .{ .collect = false, .min = 1 });

const parse_privmsg = .{
    mascii.char(':').discard(),
    irc_user.asStr(),
    mecha.string(" PRIVMSG ").discard(),
    msg_target,
    mecha.string(" :").discard(),
    mecha.many(mascii.not(mascii.control), .{ .collect = false, .min = 1 }),
    mecha.string("\r\n").discard(),
};

pub const privmsg = mecha.combine(parse_privmsg).map(toTaggedStruct(IrcServerMessage, IrcMessageType.privmsg));

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
