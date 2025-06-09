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

    input_fp: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    max_steps: ?usize = null,
    n: usize = 1,

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
            if (arg.is("-i", "--input")) {
                self.input_fp = (self.args.pop() orelse return Error.ExpectedFilepath).arg;
            } else if (arg.is("-o", "--output")) {
                self.output_dir = (self.args.pop() orelse return Error.ExpectedFolder).arg;
            } else if (arg.is("-n", "-n")) {
                self.n = try (self.args.pop() orelse return Error.ExpectedFolder).as(usize);
            } else if (arg.is("-m", "--max-step")) {
                self.max_steps = try (self.args.pop() orelse return Error.ExpectedFolder).as(usize);
            } else {
                return Error.UnsupportedArgument;
            }
        }
    }
};
