//! Ink virtual machine
const std = @import("std");
const ink = @import("ink.zig");

const InkVm = @This();

// TODO: use a more compact value type for exeuction (NaN tag?)
stack: std.BoundedArray(ink.Value, 0x1000) = .{},
states: std.BoundedArray(State, 3) = .{},

const State = union(enum) {
    text: std.ArrayListUnmanaged(u8),
    tag: std.ArrayListUnmanaged(u8),
    eval,
};
fn state(vm: *InkVm) *State {
    if (vm.states.len == 0) {
        vm.states.appendAssumeCapacity(.{ .text = .{} });
    }
    return &vm.states.slice()[vm.states.len - 1];
}

/// `allocator` must be consistent across calls
pub fn feed(vm: *InkVm, allocator: std.mem.Allocator, value: ink.Value) !Result {
    switch (vm.state().*) {
        .text => |*buf| switch (value) {
            .string => |s| if (std.mem.endsWith(u8, s, "\n")) {
                try buf.appendSlice(allocator, s[0 .. s.len - 1]);
                vm.states.len -= 1;
                return .{ .text = try buf.toOwnedSlice(allocator) };
            } else {
                try buf.appendSlice(allocator, s);
                return .more;
            },

            .collection => |c| return .{ .divert_ptr = c },

            .divert => @panic("TODO"),
            .divert_var => @panic("TODO"),
            .divert_func => @panic("TODO"),
            .divert_tunnel => @panic("TODO"),
            .external_call => @panic("TODO"),

            .assign_global => @panic("TODO"),
            .assign_temp => @panic("TODO"),

            .choice => @panic("TODO"),

            .command => |cmd| switch (cmd) {
                // TODO: warn when `done` without `end`
                .end, .done => return .end,
                .@"#" => {
                    vm.states.appendAssumeCapacity(.{ .tag = .{} });
                    return .more;
                },

                .@"/#", .@"/ev" => return error.InvalidInk, // Not valid in text state
                else => @panic("TODO"),
            },

            .void,
            .bool,
            .int,
            .float,
            .divert_target,
            .pointer,
            .variable,
            .count,
            => return error.InvalidInk, // Only valid in eval state
        },

        .tag => |*buf| switch (value) {
            .string => |s| {
                try buf.appendSlice(allocator, s);
                return .more;
            },
            .command => |cmd| switch (cmd) {
                .ev => {
                    vm.states.appendAssumeCapacity(.eval);
                    return .more;
                },
                .@"/#" => {
                    vm.states.len -= 1;
                    return .{ .tag = try buf.toOwnedSlice(allocator) };
                },

                .@"#" => return error.InvalidInk, // Only valid in text state
                .@"/ev" => return error.InvalidInk, // Only valid in eval state
                else => @panic("TODO"),
            },

            .collection,
            .divert,
            .divert_var,
            .divert_func,
            .divert_tunnel,
            .external_call,
            .assign_global,
            .assign_temp,
            .choice,
            => return error.InvalidInk, // Only valid in text state
            .void,
            .bool,
            .int,
            .float,
            .divert_target,
            .pointer,
            .variable,
            .count,
            => return error.InvalidInk, // Only valid in eval state
        },

        .eval => @panic("TODO"),
    }
}

pub const Result = union(enum) {
    more, // We need more values before we can return a result
    end,
    tag: []const u8,
    text: []const u8,
    choice: []const u8,
    divert: struct {
        target: []const u8,
        mode: enum { normal, func, tunnel },
    },
    divert_ptr: *const ink.Collection,
};
