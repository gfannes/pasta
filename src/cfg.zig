const std = @import("std");
const rubr = @import("rubr.zig");

pub const Error = error{
    CouldNotFindExecutable,
    ExpectedFilepath,
    ExpectedFolder,
    UnsupportedArgument,
};

pub const Config = struct {
    const Self = @This();

    a: std.mem.Allocator,
    args: rubr.cli.Args,

    exename: ?[]const u8 = null,

    print_help: bool = false,

    verbose: usize = 0,
    input_fp: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    iterations: usize = 1,
    max_steps: ?usize = null,
    regen_count: ?usize = null,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a, .args = rubr.cli.Args.init(a) };
    }
    pub fn deinit(self: *Self) void {
        self.args.deinit();
    }

    pub fn parse(self: *Self) !void {
        try self.args.setupFromOS();

        self.exename = (self.args.pop() orelse return Error.CouldNotFindExecutable).arg;

        while (self.args.pop()) |arg| {
            if (arg.is("-h", "--help")) {
                self.print_help = true;
            } else if (arg.is("-v", "--verbose")) {
                self.verbose = try (self.args.pop() orelse return Error.ExpectedFilepath).as(usize);
            } else if (arg.is("-i", "--input")) {
                self.input_fp = (self.args.pop() orelse return Error.ExpectedFilepath).arg;
            } else if (arg.is("-o", "--output")) {
                self.output_dir = (self.args.pop() orelse return Error.ExpectedFolder).arg;
            } else if (arg.is("-n", "--iterations")) {
                self.iterations = try (self.args.pop() orelse return Error.ExpectedFolder).as(usize);
            } else if (arg.is("-m", "--max-step")) {
                self.max_steps = try (self.args.pop() orelse return Error.ExpectedFolder).as(usize);
            } else {
                return Error.UnsupportedArgument;
            }
        }
    }

    pub fn print(self: Self, w: rubr.log.Log.Writer) !void {
        try w.print("Help for {s}\n", .{self.exename orelse "<unknown>"});
        try w.print("    -h/--help               Print this help\n", .{});
        try w.print("    -v/--verbose LEVEL      Verbosity level [optional, default is 0]\n", .{});
        try w.print("    -i/--input FILE         Input .csv file\n", .{});
        try w.print("    -o/--output FOLDER      Output folder\n", .{});
        try w.print("    -n/--iterations COUNT   Number of iterations to process [optional, default is 1]\n", .{});
        try w.print("    -m/--max-step COUNT     Maximum number of steps per iteration [optional, default is no max]\n", .{});
        try w.print("    -r/--regen COUNT        Regenerate lessons after COUNT iterations [optional, default is never]\n", .{});
        try w.print("Developed by Geert Fannes\n", .{});
    }
};
