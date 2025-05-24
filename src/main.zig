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
    config.lesson_fp = "/home/geertf/pier/test.csv";

    var app = App.init(a);
    defer app.deinit();
    try app.setup(config);

    app.model.write();

    var maybe_schedule = try app.fit();
    if (maybe_schedule) |*schedule| {
        defer schedule.deinit();
        schedule.write(app.model);
    }
}
