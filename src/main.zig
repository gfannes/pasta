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

    var myApp = app.App.init(a, &log);
    defer myApp.deinit();
    try myApp.setup(config);

    var solutions = std.ArrayList(app.Solution).init(a);
    defer {
        for (solutions.items) |*solution|
            solution.deinit();
        solutions.deinit();
    }

    for (0..config.n) |iteration| {
        std.debug.print("Iteration {}\n", .{iteration});
        const maybe_solution = myApp.fit() catch null;
        if (maybe_solution) |solution| {
            try solutions.append(solution);
        }
    }

    const Fn = struct {
        pub fn ascending(_: void, x: app.Solution, y: app.Solution) bool {
            return x.unfit < y.unfit;
        }
        pub fn descending(_: void, x: app.Solution, y: app.Solution) bool {
            return y.unfit < x.unfit;
        }
    };

    if (config.output_dir) |output_dir| {
        std.sort.block(app.Solution, solutions.items, {}, Fn.ascending);
        try std.fs.cwd().makePath(output_dir);
    } else {
        std.sort.block(app.Solution, solutions.items, {}, Fn.descending);
    }

    for (solutions.items, 0..) |solution, ix| {
        var output_log = rubr.log.Log{};
        output_log.init();
        defer output_log.deinit();

        if (config.output_dir) |dir| {
            const fp = try std.fmt.allocPrint(a, "{s}/solution-{:04}.txt", .{ dir, ix });
            defer a.free(fp);

            try output_log.toFile(fp);
        }

        try output_log.print("Unfit {}\n", .{solution.unfit});
        try solution.schedule.write(output_log.writer(), myApp.model);
    }
}
