//! User-facing API
const std = @import("std");

const ink = @import("ink.zig");

pub const max_ink_version = 21;

pub const Story = struct {
    arena: std.heap.ArenaAllocator,
    root: ink.Collection,

    pub fn deinit(story: Story) void {
        story.arena.deinit();
    }

    pub fn parse(allocator: std.mem.Allocator, r: anytype) !Story {
        var temp_arena = std.heap.ArenaAllocator.init(allocator);
        defer temp_arena.deinit();
        var jr = std.json.reader(temp_arena.allocator(), r);
        const file = try std.json.parseFromTokenSourceLeaky(
            std.json.Value,
            temp_arena.allocator(),
            &jr,
            .{},
        );

        if (file != .object) return error.InvalidInk;
        const version = try ink.get(.integer, file.object, "inkVersion") orelse return error.InvalidInk;
        if (version > max_ink_version) {
            return error.UnsupportedInkVersion;
        }

        if (try ink.get(.object, file.object, "listDefs")) |list_defs| {
            if (list_defs.count() > 0) {
                return error.UnsupportedInk; // TODO: I don't know what this field is for
            }
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const root_json = try ink.get(.array, file.object, "root") orelse return error.InvalidInk;
        const root = try ink.Collection.parse(arena.allocator(), root_json);

        return Story{
            .arena = arena,
            .root = root,
        };
    }
};
