//! User-facing API
const std = @import("std");
const log = std.log.scoped(.ink);

const ink = @import("ink.zig");
const InkVm = @import("InkVm.zig");

pub const max_ink_version = 21;

pub const Story = struct {
    arena: std.heap.ArenaAllocator,
    root: *const ink.Collection,

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
        const root = try ink.Collection.parse(arena.allocator(), null, root_json);

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
    error_msg: ?[]const u8 = null, // Will be populated iff `next` returned `error.Ink`

    choice: bool = false,
    vm: InkVm = .{},
    current: ?*const ink.Collection = null,
    idx: usize = 0,
    arena: std.heap.ArenaAllocator.State = .{},

    pub fn next(run: *Runner) !?Chunk {
        std.debug.assert(!run.choice); // Continued without selecting a choice
        if (run.ended) return null;

        var arena = run.arena.promote(run.allocator);
        _ = arena.reset(.{ .retain_with_limit = 0x4000 }); // TODO: check to make sure this limit is reasonable
        defer run.arena = arena.state;

        run.error_msg = null;

        var choices: Chunk.Choices = .{};
        var tags = std.ArrayList([]const u8).init(arena.allocator());
        loop: while (true) {
            const cur = run.current orelse run.story.root;
            if (run.idx >= cur.array.len) {
                if (cur.parent) |p| {
                    // FIXME: slow
                    for (p.array.items(.tags), p.array.items(.data), 0..) |tag, data, i| {
                        if (tag == .collection and data.collection == cur) {
                            run.idx = i + 1;
                            run.current = p;
                            continue :loop;
                        }
                    }
                }
                return error.InvalidInk; // Reached end of collection with no way to continue
            }

            const val = cur.array.get(run.idx);
            if (val == .command and val.command == .done and choices.len > 0) {
                run.choice = true;
                return .{ .choices = choices };
            }
            run.idx += 1;

            switch (try run.vm.feed(run.allocator, arena.allocator(), val)) {
                .more => {},
                .end => {
                    run.ended = true;
                    return null;
                },

                .tag => |tag| try tags.append(tag),
                .text => |text| {
                    if (choices.len > 0) return error.InvalidInk; // Text after choices
                    return .{ .text = .{
                        .text = text,
                        .tags = try tags.toOwnedSlice(),
                    } };
                },

                .choice => |choice| {
                    try choices.append(arena.allocator(), .{
                        .choice = .{
                            .text = choice.text,
                            .tags = try tags.toOwnedSlice(),
                        },
                        .target = choice.target,
                    });
                },

                .divert => |divert| {
                    if (divert.mode != .normal) {
                        @panic("TODO");
                    }
                    try run.go(divert.target);
                },
                .divert_ptr => |ptr| {
                    run.current = ptr;
                    run.idx = 0;
                },

                .err => |msg| run.error_msg = msg,
            }
        }
    }

    pub fn go(run: *Runner, target_path: []const u8) !void {
        var path = target_path;
        var coll = run.story.root;
        if (std.mem.startsWith(u8, path, ".^.")) {
            if (run.current) |c| coll = c;
            path = path[".^.".len..];
        }
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, "^")) {
                coll = coll.parent orelse {
                    return error.InvalidInk; // Tried to get parent of root collection
                };
            } else {
                const value = if (std.fmt.parseInt(usize, part, 10)) |idx|
                    coll.array.get(idx)
                else |_|
                    coll.dict.get(part) orelse {
                        log.err("Can't find divert target: '{s}' (in path {s})", .{ part, path });
                        return error.InvalidInk; // Invalid divert target
                    };
                if (value != .collection) {
                    return error.InvalidInk; // Divert non-collection
                }
                coll = value.collection;
            }
        }

        run.current = coll;
        run.idx = 0;
        run.choice = false;
    }

    pub const ExecError = error{
        OutOfMemory,
        StackOverflow, // The Ink program has overflowed one or more of the execution stacks
        InvalidInk, // The file structure is invalid
        Ink, // The Ink program had an error
    };
};

pub const Chunk = union(enum) {
    text: Content,
    choices: Choices,

    pub const Choices = std.MultiArrayList(struct {
        choice: Content,
        target: []const u8,
    });
};
pub const Content = struct {
    text: []const u8,
    tags: []const []const u8,
};
