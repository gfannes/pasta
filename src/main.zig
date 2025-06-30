const std = @import("std");
const cfg = @import("cfg.zig");
const rubr = @import("rubr.zig");
const app = @import("app.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var config = cfg.Config.init(a);
    defer config.deinit();
    try config.parse();

    var log = rubr.log.Log{};
    log.init();
    defer log.deinit();

    log.setLevel(config.verbose);

    if (config.print_help) {
        try config.print(log.writer());
        return;
    }

    var my_app = app.App.init(a, &log);
    defer my_app.deinit();

    try my_app.setup(config);

    try my_app.learn();

    try my_app.writeOutput();
}
