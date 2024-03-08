//! Ink types
const std = @import("std");
const log = std.log.scoped(.ink);

pub const ParseError = error{ InvalidInk, OutOfMemory };

// TODO: compact this union
pub const Value = union(enum) {
    void,
    string: []const u8,
    command: Command,
    bool: bool,
    int: i64,
    float: f64,
    collection: *const Collection,
    divert_target: []const u8,
    pointer: struct {
        varname: []const u8,
        const_idx: i64,
    },

    divert: Divert,
    divert_var: Divert,
    divert_func: Divert,
    divert_tunnel: Divert,
    external_call: struct {
        target: []const u8,
        args: i64,
        conditional: bool,
    },

    assign_global: Assign,
    assign_temp: Assign,

    variable: []const u8,
    count: []const u8,

    choice: struct {
        target: []const u8,
        flags: packed struct(u5) {
            has_condition: bool = false,
            has_start_content: bool = false,
            has_choice_only_content: bool = false,
            is_invisible_default: bool = false,
            once_only: bool = true,
        },
    },

    const Divert = struct {
        target: []const u8,
        conditional: bool,
    };
    const Assign = struct {
        varname: []const u8,
        re: bool,
    };

    pub fn parse(allocator: std.mem.Allocator, json: std.json.Value) ParseError!Value {
        switch (json) {
            .string => |s| if (std.mem.eql(u8, s, "void")) {
                return .void;
            } else if (std.mem.eql(u8, s, "\n")) {
                return .{ .string = "\n" };
            } else if (std.mem.startsWith(u8, s, "^")) {
                return .{ .string = try allocator.dupe(u8, s[1..]) };
            } else {
                return .{ .command = std.meta.stringToEnum(Command, s) orelse {
                    log.err("Unknown command: {s}", .{s});
                    return error.InvalidInk;
                } };
            },
            .bool => |b| return .{ .bool = b },
            .integer => |i| return .{ .int = i },
            .float => |f| return .{ .float = f },
            .array => |array| {
                const c = try allocator.create(Collection);
                c.* = try Collection.parse(allocator, array);
                return .{ .collection = c };
            },

            // TODO: this is a horrible mess that is begging to be refactored (hint: use an enum)
            .object => |obj| if (try get(.string, obj, "^->")) |target| {
                return .{ .divert_target = try allocator.dupe(u8, target) };
            } else if (try get(.string, obj, "^var")) |varname| {
                return .{ .pointer = .{
                    .varname = try allocator.dupe(u8, varname),
                    .const_idx = try get(.integer, obj, "ci") orelse -1,
                } };
            } else if (try parseDivert(allocator, obj, "->")) |divert| {
                if (try get(.bool, obj, "var") orelse false) {
                    return .{ .divert_var = divert };
                } else {
                    return .{ .divert = divert };
                }
            } else if (try parseDivert(allocator, obj, "f()")) |divert| {
                return .{ .divert_func = divert };
            } else if (try parseDivert(allocator, obj, "->t->")) |divert| {
                return .{ .divert_tunnel = divert };
            } else if (try parseDivert(allocator, obj, "x()")) |divert| {
                return .{ .external_call = .{
                    .target = divert.target,
                    .args = try get(.integer, obj, "exArgs") orelse 0,
                    .conditional = divert.conditional,
                } };
            } else if (try get(.string, obj, "VAR=")) |varname| {
                return .{ .assign_global = .{
                    .varname = try allocator.dupe(u8, varname),
                    .re = try get(.bool, obj, "re") orelse false,
                } };
            } else if (try get(.string, obj, "temp=")) |varname| {
                return .{ .assign_temp = .{
                    .varname = try allocator.dupe(u8, varname),
                    .re = try get(.bool, obj, "re") orelse false,
                } };
            } else if (try get(.string, obj, "VAR?")) |varname| {
                return .{ .variable = try allocator.dupe(u8, varname) };
            } else if (try get(.string, obj, "CNT?")) |target| {
                return .{ .count = try allocator.dupe(u8, target) };
            } else if (try get(.string, obj, "*")) |target| {
                const duped = try allocator.dupe(u8, target);
                if (try get(.integer, obj, "flg")) |flg| {
                    const flags: u5 = @intCast(flg);
                    return .{ .choice = .{ .target = duped, .flags = @bitCast(flags) } };
                } else {
                    return .{ .choice = .{ .target = duped, .flags = .{} } };
                }
            } else {
                log.err("Unknown object construct with keys {s}", .{obj.keys()});
                return error.InvalidInk;
            },

            else => {
                log.err("Unknown item: {}", .{json});
                return error.InvalidInk;
            },
        }
    }

    fn parseDivert(allocator: std.mem.Allocator, obj: std.json.ObjectMap, field: []const u8) !?Divert {
        const target = try get(.string, obj, field) orelse return null;
        return .{
            .target = try allocator.dupe(u8, target),
            .conditional = try get(.bool, obj, "c") orelse false,
        };
    }
};

pub const Command = enum {
    // The C# impl mentions G> and G< glue commands as well as <>, but they don't seem to be used and I don't know what they're supposed to do
    @"<>",

    // This isn't properly documented by the C# impl either
    @"#",
    @"/#",

    ev,
    out,
    @"/ev",
    du,
    pop,
    @"->->",
    @"~ret",
    str,
    @"/str",
    nop,
    choiceCnt,
    turns,
    visit,
    seq,
    rnd,
    thread,
    done,
    end,

    @"+",
    @"-",
    @"/",
    @"*",
    @"%",
    @"~",
    @"==",
    @">",
    @"<",
    @">=",
    @"<=",
    @"!=",
    @"!",
    @"&&",
    @"||",
    MIN,
    MAX,
};

pub const Collection = struct {
    name: []const u8 = "",
    tracking: packed struct(u3) {
        visits: bool = false,
        turns: bool = false,
        count_start_only: bool = false,
    } = .{},
    array: std.MultiArrayList(Value) = .{},
    dict: std.StringArrayHashMapUnmanaged(Value) = .{},

    pub fn parse(allocator: std.mem.Allocator, json: std.json.Array) ParseError!Collection {
        var coll: Collection = .{};

        if (json.items.len == 0) {
            return error.InvalidInk;
        }
        for (json.items[0 .. json.items.len - 1]) |val| {
            try coll.array.append(allocator, try Value.parse(allocator, val));
        }

        switch (json.items[json.items.len - 1]) {
            .null => {},
            .object => |json_dict| for (json_dict.keys(), json_dict.values()) |key, val| {
                if (std.mem.eql(u8, key, "#n")) {
                    if (val != .string) return error.InvalidInk;
                    coll.name = try allocator.dupe(u8, val.string);
                } else if (std.mem.eql(u8, key, "#f")) {
                    if (val != .integer) return error.InvalidInk;
                    const flags: u3 = @intCast(val.integer);
                    coll.tracking = @bitCast(flags);
                } else {
                    try coll.dict.put(allocator, key, try Value.parse(allocator, val));
                }
            },
            else => return error.InvalidInk,
        }

        return coll;
    }
};

// Get field from json object, with type checking
pub fn get(comptime tag: std.meta.Tag(std.json.Value), obj: std.json.ObjectMap, field: []const u8) !?std.meta.fieldInfo(std.json.Value, tag).type {
    if (obj.get(field)) |v| {
        if (v != tag) return error.InvalidInk;
        return @field(v, @tagName(tag));
    } else {
        return null;
    }
}
