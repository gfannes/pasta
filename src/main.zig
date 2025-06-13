const std = @import("std");
const app = @import("app.zig");
const cfg = @import("cfg.zig");
const mdl = @import("mdl.zig");
const rubr = @import("rubr.zig");

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

    if (config.print_help) {
        try config.print(log.writer());
        return;
    }

    log.setLevel(config.verbose);

    var myApp = app.App.init(a, &log);
    defer myApp.deinit();
    try myApp.setup(config);

    try myApp.learn();

    try myApp.writeOutput();
}
