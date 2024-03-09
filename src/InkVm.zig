//! Ink virtual machine
const std = @import("std");
const ink = @import("ink.zig");

const InkVm = @This();

// TODO: use a more compact value type for exeuction (NaN tag?)
stack: std.BoundedArray(ink.Value, 0x1000) = .{},
globals: std.StringHashMapUnmanaged(ink.Value) = .{},
temps: std.StringHashMapUnmanaged(ink.Value) = .{},
state_stack: std.BoundedArray(State, 0x100) = .{},

const State = union(enum) {
    text: std.ArrayListUnmanaged(u8),
    tag: std.ArrayListUnmanaged(u8),
    eval,
};
fn state(vm: *InkVm) *State {
    if (vm.state_stack.len == 0) {
        vm.state_stack.appendAssumeCapacity(.{ .text = .{} });
    }
    return &vm.state_stack.slice()[vm.state_stack.len - 1];
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

fn pushValue(vm: *InkVm, value: ink.Value) !void {
    vm.stack.append(value) catch return error.StackOverflow;
}
fn popValue(vm: *InkVm) !ink.Value {
    return vm.stack.popOrNull() orelse {
        return error.InvalidInk; // Stack underflow
    };
}

fn getVar(vm: *InkVm, name: []const u8) ?ink.Value {
    return vm.globals.get(name) orelse vm.temps.get(name);
}

fn err(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Result {
    return .{ .err = try std.fmt.allocPrint(allocator, fmt, args) };
}

/// Feed a value to the VM
/// `gpa` is used for long-lived allocations, such as variable values
/// `arena` is used for anything that is only used as part of the returned `Result`
pub fn feed(
    vm: *InkVm,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    value: ink.Value,
) !Result {
    switch (value) {
        .string => |s| switch (vm.state().*) {
            .text => |*buf| if (std.mem.endsWith(u8, s, "\n")) {
                try buf.appendSlice(arena, s[0 .. s.len - 1]);
                vm.state_stack.len -= 1;
                return .{ .text = try buf.toOwnedSlice(arena) };
            } else {
                try buf.appendSlice(arena, s);
                return .more;
            },

            .tag => |*buf| {
                try buf.appendSlice(arena, s);
                return .more;
            },

            .eval => @panic("TODO"),
        },

        .collection => |c| {
            _ = try vm.assertState(.text);
            return .{ .divert_ptr = c };
        },

        .divert => |divert| {
            _ = try vm.assertState(.text);
            if (divert.conditional) {
                @panic("TODO");
            }
            return .{ .divert = .{
                .target = divert.target,
                .mode = .normal,
            } };
        },
        .divert_var => |divert| {
            _ = try vm.assertState(.text);
            if (divert.conditional) {
                @panic("TODO");
            }
            const target = vm.getVar(divert.target) orelse {
                return err(arena, "Undefined variable: {s}", .{divert.target});
            };
            if (target != .divert_target) {
                return err(arena, "Target of variable divert must be a divert target", .{});
            }
            return .{ .divert = .{
                .target = target.divert_target,
                .mode = .normal,
            } };
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
                vm.state_stack.append(.{ .tag = .{} }) catch return error.StackOverflow;
                return .more;
            },
            .@"/#" => {
                const buf = try vm.assertState(.tag);
                vm.state_stack.len -= 1;
                return .{ .tag = try buf.toOwnedSlice(arena) };
            },

            .ev => {
                if (vm.state().* == .eval) return error.InvalidInk; // Can't nest eval states
                vm.state_stack.append(.eval) catch return error.StackOverflow;
                return .more;
            },
            .@"/ev" => {
                try vm.assertState(.eval);
                @panic("TODO");
            },

            .str => {
                try vm.assertState(.eval);
                vm.state_stack.append(.{ .text = .{} }) catch return error.StackOverflow;
                return .more;
            },
            .@"/str" => {
                const buf = try vm.assertState(.text);
                if (vm.state_stack.len == 1) {
                    return error.InvalidInk; // Attempted to exit `str` mode when not in it
                }
                defer buf.deinit(arena);
                vm.state_stack.len -= 1;

                // TODO: would be nice if we didn't have to copy. Not sure that's worth storing the allocator in state though. Maybe just bite the bullet and add a `str` state
                try vm.pushValue(.{ .string = try gpa.dupe(u8, buf.items) });
                return .more;
            },

            else => @panic("TODO"),
        },

        inline .assign_global, .assign_temp => |a, variant| {
            try vm.assertState(.eval);

            const map = switch (variant) {
                .assign_global => &vm.globals,
                .assign_temp => &vm.temps,
                else => @compileError("unreachable"),
            };

            const exists = map.get(a.varname) != null;
            if (a.re != exists) {
                return error.InvalidInk; // Variable created twice, or not created before assignment
            }

            try map.put(gpa, a.varname, try vm.popValue());

            return .more;
        },

        .void, .bool, .int, .float, .divert_target, .pointer => {
            try vm.assertState(.eval);
            try vm.pushValue(value);
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

    err: []const u8,
};
