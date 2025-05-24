const std = @import("std");

pub const Config = struct {
    const Self = @This();

    a: std.mem.Allocator,
    lesson_fp: []const u8 = &.{},

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }
};
