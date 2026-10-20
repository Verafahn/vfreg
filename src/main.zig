const std = @import("std");
const Io = std.Io;
const vfreg = @import("vfreg");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("usage: vfreg <input.svd> [output.zig]\n", .{});
        return;
    }

    const input_path = args[1];
    const data = try Io.Dir.cwd().readFileAlloc(
        io,
        input_path,
        arena,
        .limited(512 * 1024 * 1024),
    );

    var parser: vfreg.parser.Parser = .init(arena, data);
    defer parser.deinit();

    const device = parser.parse() catch |err| {
        if (parser.diagnostic) |diagnostic| {
            std.debug.print(
                "error: {s} ({d}:{d})\n",
                .{ diagnostic.message, diagnostic.line, diagnostic.column },
            );
        } else {
            std.debug.print("error: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };

    const code = try vfreg.generator.generate(arena, device);

    if (args.len >= 3) {
        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = args[2],
            .data = code,
        });
    } else {
        try Io.File.stdout().writeStreamingAll(io, code);
    }
}
