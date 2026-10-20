const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    _ = args;
    // const svd = args[0];
    const svd = "STM32F103.svd";

    const infile = try Io.Dir.cwd().openFile(io, svd, .{});
    defer infile.close(io);

    var buffer: [64]u8 = undefined;
    var reader = infile.reader(io, &buffer);
    const r = &reader.interface;

    _ = r;
}
