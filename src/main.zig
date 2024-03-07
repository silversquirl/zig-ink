const std = @import("std");
const ink = @import("ink");

pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    _ = args.skip();
    while (args.next()) |arg| {
        std.debug.print("Parsing {s}\n", .{arg});
        var f = try std.fs.cwd().openFile(arg, .{});
        defer f.close();

        const story = try ink.Story.parse(std.heap.page_allocator, f.reader());
        defer story.deinit();
        std.debug.print("Success!\n", .{});
    }
}
