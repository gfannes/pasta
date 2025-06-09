const std = @import("std");
const App = @import("app.zig").App;
const cfg = @import("cfg.zig");
const mdl = @import("mdl.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var config = cfg.Config.init(a);
    defer config.deinit();
    try config.parse();

    var app = App.init(a);
    defer app.deinit();
    try app.setup(config);

    for (0..config.n) |iteration| {
        std.debug.print("Iteration {}\n", .{iteration});
        var maybe_schedule = app.fit() catch null;
        if (maybe_schedule) |*schedule| {
            defer schedule.deinit();
            try schedule.write(app.model);
        }
    }
}
