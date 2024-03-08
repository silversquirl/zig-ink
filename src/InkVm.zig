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

fn assertState(
    vm: *InkVm,
    comptime s: std.meta.Tag(State),
) !switch (std.meta.fieldInfo(State, s).type) {
    void => void,
    else => |T| *T,
} {
    const st = vm.state();
    if (st.* != s) return error.InvalidInk;
    return switch (std.meta.fieldInfo(State, s).type) {
        void => {},
        else => &@field(st.*, @tagName(s)),
    };
}

/// `allocator` must be consistent across calls
pub fn feed(vm: *InkVm, allocator: std.mem.Allocator, value: ink.Value) !Result {
    switch (value) {
        .string => |s| switch (vm.state().*) {
            .text => |*buf| if (std.mem.endsWith(u8, s, "\n")) {
                try buf.appendSlice(allocator, s[0 .. s.len - 1]);
                vm.states.len -= 1;
                return .{ .text = try buf.toOwnedSlice(allocator) };
            } else {
                try buf.appendSlice(allocator, s);
                return .more;
            },

            .tag => |*buf| {
                try buf.appendSlice(allocator, s);
                return .more;
            },

            .eval => @panic("TODO"),
        },

        .collection => |c| {
            _ = try vm.assertState(.text);
            return .{ .divert_ptr = c };
        },

        .divert => {
            _ = try vm.assertState(.text);
            @panic("TODO");
        },
        .divert_var => {
            _ = try vm.assertState(.text);
            @panic("TODO");
        },
        .divert_func => {
            _ = try vm.assertState(.text);
            @panic("TODO");
        },
        .divert_tunnel => {
            _ = try vm.assertState(.text);
            @panic("TODO");
        },
        .external_call => {
            _ = try vm.assertState(.text);
            @panic("TODO");
        },

        .assign_global => {
            _ = try vm.assertState(.text);
            @panic("TODO");
        },
        .assign_temp => {
            _ = try vm.assertState(.text);
            @panic("TODO");
        },

        .choice => {
            _ = try vm.assertState(.text);
            @panic("TODO");
        },

        .command => |cmd| switch (cmd) {
            // TODO: warn when `done` without `end`
            .end, .done => {
                _ = try vm.assertState(.text);
                return .end;
            },

            .@"#" => {
                _ = try vm.assertState(.text);
                vm.states.appendAssumeCapacity(.{ .tag = .{} });
                return .more;
            },
            .@"/#" => {
                const buf = try vm.assertState(.tag);
                vm.states.len -= 1;
                return .{ .tag = try buf.toOwnedSlice(allocator) };
            },

            .ev => {
                if (vm.state().* == .eval) return error.InvalidInk; // Can't nest eval states
                vm.states.appendAssumeCapacity(.eval);
                return .more;
            },
            .@"/ev" => {
                try vm.assertState(.eval);
                @panic("TODO");
            },

            else => @panic("TODO"),
        },

        .void, .bool, .int, .float, .divert_target, .pointer => {
            try vm.assertState(.eval);
            vm.stack.append(value) catch return error.StackOverflow;
            return .more;
        },
        .variable => {
            try vm.assertState(.eval);
            @panic("TODO");
        },
        .count => {
            try vm.assertState(.eval);
            @panic("TODO");
        },
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
