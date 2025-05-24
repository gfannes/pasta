const std = @import("std");
const rubr = @import("rubr");

pub const Model = struct {
    const Self = @This();
    pub const Count = struct {
        classes: usize = 0,
        groups: usize = 0,
        courses: usize = 0,
        hours: usize = 0,
    };

    a: std.mem.Allocator,
    classes: []Class = &.{},
    groups: []Group = &.{},
    courses: []Course = &.{},
    schedule: Schedule,

    pub fn init(a: std.mem.Allocator) Self {
        return Model{ .a = a, .schedule = Schedule.init(a) };
    }
    pub fn deinit(self: *Self) void {
        self.a.free(self.classes);
        self.a.free(self.groups);
        self.a.free(self.courses);
        self.schedule.deinit();
    }
    pub fn alloc(self: *Self, count: Count) !void {
        self.classes = try self.a.alloc(Class, count.classes);
        self.groups = try self.a.alloc(Group, count.groups);
        self.courses = try self.a.alloc(Course, count.courses);
        try self.schedule.alloc(count.hours, count.classes);
    }
};

pub const Schedule = struct {
    const Self = @This();

    a: std.mem.Allocator,
    hour__class__lesson: [][]?Lesson = &.{},

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        for (self.hour__class__lesson) |e|
            self.a.free(e);
        self.a.free(self.hour__class__lesson);
    }
    pub fn alloc(self: *Self, hours: usize, classes: usize) !void {
        self.hour__class__lesson = try self.a.alloc([]Lesson, hours);
        for (self.hour__class__lesson) |*class__lesson| {
            class__lesson.* = try self.a.alloc(?Lesson, classes);
            @memset(class__lesson.*, null);
        }
    }
};

pub const Class = struct {
    const Self = @This();
    name: []const u8 = &.{},
};

pub const Group = struct {
    const Self = @This();
    name: []const u8 = &.{},
};

pub const Course = struct {
    const Self = @This();
    name: []const u8 = &.{},
};

pub const Section = struct {
    const Self = @This();
};

pub const Lesson = struct {
    const Self = @This();
};

pub const Hour = struct {
    const Self = @This();
};

pub const Constraint = struct {
    const Self = @This();
};
