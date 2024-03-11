const std = @import("std");
const ink = @import("ink");

pub fn main() !void {
    const stdout = std.io.getStdOut();
    const out = stdout.writer();
    const tty = std.io.tty.detectConfig(stdout);

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    _ = args.skip();
    while (args.next()) |arg| {
        try tty.setColor(out, .bright_cyan);
        try out.print(" --- Loading {s}...\n", .{arg});
        try tty.setColor(out, .reset);

        const story = a: {
            const f = try std.fs.cwd().openFile(arg, .{});
            defer f.close();
            break :a try ink.Story.parse(std.heap.page_allocator, f.reader());
        };
        defer story.deinit();

        try tty.setColor(out, .bright_green);
        try out.print(" --- Running\n", .{});
        try tty.setColor(out, .reset);

        var run: ink.Runner = .{
            .allocator = std.heap.page_allocator,
            .story = &story,
        };
        while (try run.next()) |chunk| {
            switch (chunk) {
                .text => |text| try printContent(out, tty, text),
                .choices => |choices| {
                    for (choices.items(.choice), 0..) |choice, i| {
                        try tty.setColor(out, .yellow);
                        if (i == 0) {
                            try tty.setColor(out, .bold);
                            try out.writeAll(" --> ");
                        } else {
                            try out.writeAll("  *  ");
                        }
                        try printContent(out, tty, choice);
                    }
                    try run.go(choices.items(.target)[0]); // TODO
                },
            }
        }

        try tty.setColor(out, .bright_green);
        try out.print(" --- Finished\n\n", .{});
        try tty.setColor(out, .reset);
    }
}

fn printContent(out: anytype, tty: std.io.tty.Config, content: ink.Content) !void {
    try out.print("{s}", .{content.text});
    try tty.setColor(out, .black);
    for (content.tags) |tag| {
        try out.print(" #{s}", .{tag});
    }
    try tty.setColor(out, .reset);
    try out.print("\n", .{});
}
