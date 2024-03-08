//! User-facing API
const std = @import("std");

const ink = @import("ink.zig");
const InkVm = @import("InkVm.zig");

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

pub const Runner = struct {
    allocator: std.mem.Allocator,
    story: *const Story,
    ended: bool = false,

    vm: InkVm = .{},
    current: ?*const ink.Collection = null,
    idx: usize = 0,
    arena: std.heap.ArenaAllocator.State = .{},

    pub fn next(run: *Runner) !?Content {
        if (run.ended) return null;

        var arena = run.arena.promote(run.allocator);
        _ = arena.reset(.{ .retain_with_limit = 0x4000 }); // TODO: check to make sure this limit is reasonable
        defer run.arena = arena.state;

        var tags = std.ArrayList([]const u8).init(arena.allocator());
        while (true) {
            const cur = run.current orelse &run.story.root;
            if (run.idx >= cur.array.len) {
                return error.InvalidInk;
            }
            const val = cur.array.get(run.idx);
            run.idx += 1;
            switch (try run.vm.feed(arena.allocator(), val)) {
                .more => {},
                .end => {
                    run.ended = true;
                    return null;
                },

                .tag => |tag| try tags.append(tag),
                .text => |text| return .{
                    .text = text,
                    .tags = try tags.toOwnedSlice(),
                },
                .choice => @panic("TODO"),

                .divert => @panic("TODO"),
                .divert_ptr => |ptr| {
                    run.current = ptr;
                    run.idx = 0;
                },
            }
        }
    }

    pub fn choices(run: Runner) ?[]Content {
        _ = run;
        @compileError("TODO");
    }

    pub fn choosePathString(run: Runner, path: []const u8) void {
        _ = .{ run, path };
        @compileError("TODO");
    }

    pub const ExecError = error{
        OutOfMemory,
        StackOverflow, // The Ink program has overflowed one or more of the execution stacks
        InvalidInk, // The file structure is invalid
        Ink, // The Ink program had an error
    };
};

pub const Content = struct {
    text: []const u8,
    tags: []const []const u8,
};
