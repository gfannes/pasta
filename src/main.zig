const std = @import("std");
const cfg = @import("cfg.zig");
const rubr = @import("rubr.zig");
const app = @import("app.zig");

pub fn main() !void {
    var env_inst = rubr.Env.Instance{};
    env_inst.init();
    defer env_inst.deinit();

    const env = env_inst.env();

    var config = cfg.Config.init(env);
    defer config.deinit();
    try config.parse();

    env_inst.log.setLevel(config.verbose);

    if (config.print_help) {
        try config.print(env.log.writer());
        return;
    }

    var my_app = app.App.init(env);
    defer my_app.deinit();

    try my_app.setup(config);

    try my_app.learn();

    try my_app.writeOutput();
}
