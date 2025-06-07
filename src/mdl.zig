const std = @import("std");
const rubr = @import("rubr");

pub const Count = struct {
    classes: usize = 0,
    groups: usize = 0,
    courses: usize = 0,
    lessons: usize = 0,
};

pub const Model = struct {
    const Self = @This();

    a: std.mem.Allocator,
    classes: []Class = &.{},
    groups: []Group = &.{},
    courses: []Course = &.{},
    lessons: []Lesson = &.{},

    pub fn init(a: std.mem.Allocator) Self {
        return Model{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        for (self.classes) |class|
            self.a.free(class.courses);
        self.a.free(self.classes);

        self.a.free(self.groups);

        for (self.courses) |course|
            self.a.free(course.classes);
        self.a.free(self.courses);

        self.a.free(self.lessons);
    }
    pub fn alloc(self: *Self, count: Count) !void {
        self.classes = try self.a.alloc(Class, count.classes);
        @memset(self.classes, .{});
        self.groups = try self.a.alloc(Group, count.groups);
        @memset(self.groups, .{});
        self.courses = try self.a.alloc(Course, count.courses);
        @memset(self.courses, .{});
        self.lessons = try self.a.alloc(Lesson, count.lessons);
        @memset(self.lessons, .{});
    }

    pub fn write(self: Self) void {
        for (self.groups, 0..) |group, group_ix| {
            std.debug.print("Group '{s}' ({}):", .{ group.name, group.count });
            for (self.classes) |class| {
                if (class.group == group_ix)
                    std.debug.print(" {s} ({})", .{ class.name, class.count });
            }
            std.debug.print("\n", .{});
        }
        for (self.courses, 0..) |course, course_ix| {
            std.debug.print("Course '{s}' ({}h): ", .{ course.name, course.hours });
            for (self.classes) |class| {
                if (std.mem.indexOfScalar(Course.Ix, class.courses, course_ix)) |_| {
                    std.debug.print(" {s}", .{class.name});
                }
            }
            std.debug.print("\n", .{});
        }
    }
};

pub const Schedule = struct {
    const Self = @This();

    a: std.mem.Allocator,
    hour__class__lesson: [][]?Lesson.Ix = &.{},

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        for (self.hour__class__lesson) |e|
            self.a.free(e);
        self.a.free(self.hour__class__lesson);
    }
    pub fn copy(self: *Self) !Self {
        var ret = Self.init(self.a);
        errdefer ret.deinit();
        ret.hour__class__lesson = try ret.a.alloc([]?Lesson.Ix, self.hour__class__lesson.len);
        for (ret.hour__class__lesson, 0..) |*dst, ix| {
            const src = self.hour__class__lesson[ix];
            dst.* = try ret.a.alloc(?Lesson.Ix, src.len);
            std.mem.copyForwards(?Lesson.Ix, dst.*, src);
        }
        return ret;
    }
    pub fn alloc(self: *Self, hours: usize, classes: usize) !void {
        self.hour__class__lesson = try self.a.alloc([]?Lesson.Ix, hours);
        for (self.hour__class__lesson) |*class__lesson| {
            class__lesson.* = try self.a.alloc(?Lesson.Ix, classes);
            @memset(class__lesson.*, null);
        }
    }

    pub fn isFree(self: Schedule, hour: usize, course: *const Course) bool {
        const class__lesson = self.hour__class__lesson[hour];

        for (course.classes) |class_ix| {
            if (class__lesson[class_ix]) |blocking_lesson| {
                _ = blocking_lesson;
                // std.debug.print("\tHour {} is blocked for Class {} by Lesson {}\n", .{ hour, class_ix, blocking_lesson });
                return false;
            }
        }

        return true;
    }

    pub fn insertLesson(self: *Schedule, hour: usize, course: *const Course, lesson_ix: ?Lesson.Ix) void {
        const class__lesson = self.hour__class__lesson[hour];
        for (course.classes) |class_ix|
            class__lesson[class_ix] = lesson_ix;
    }

    pub fn write(self: Self, model: Model) !void {
        var max_width: usize = 0;
        for (self.hour__class__lesson) |class__lesson| {
            for (class__lesson) |lesson_ix| {
                if (lesson_ix) |ix| {
                    const lesson = model.lessons[ix];
                    const course = model.courses[lesson.course_ix];
                    max_width = @max(max_width, course.name.len + 2);
                }
            }
        }

        const Line = struct {
            const My = @This();
            a: std.mem.Allocator,
            width: usize,
            buf: []u8 = &.{},
            fn init(width: usize, a: std.mem.Allocator) !My {
                std.debug.print("|", .{});
                return My{ .a = a, .width = width, .buf = try a.alloc(u8, width) };
            }
            fn deinit(my: *My) void {
                std.debug.print("\n", .{});
                my.a.free(my.buf);
            }
            fn print(my: *My, comptime fmt: []const u8, options: anytype) void {
                for (my.buf) |*ch|
                    ch.* = ' ';
                _ = std.fmt.bufPrint(my.buf, fmt, options) catch {};
                std.debug.print(" {s} |", .{my.buf});
            }
        };

        {
            var line = try Line.init(max_width, self.a);
            defer line.deinit();
            line.print("", .{});
            for (model.classes) |class| {
                line.print("{s}", .{class.name});
            }
        }

        for (self.hour__class__lesson, 0..) |class__lesson, hour_ix| {
            var line = try Line.init(max_width, self.a);
            defer line.deinit();
            // _ = hour_ix;
            line.print("{}", .{hour_ix});
            for (class__lesson, 0..) |lesson_ix, class_ix| {
                _ = class_ix;
                if (lesson_ix) |ix| {
                    const lesson = model.lessons[ix];
                    const course = model.courses[lesson.course_ix];
                    line.print("{s}-{}", .{ course.name, lesson.hour });
                } else {
                    line.print("", .{});
                }
            }
        }
    }
};

pub const Class = struct {
    const Self = @This();
    pub const Ix = usize;

    name: []const u8 = &.{},
    group: Group.Ix = 0,
    count: usize = 0,
    courses: []Course.Ix = &.{},
};

pub const Group = struct {
    const Self = @This();
    pub const Ix = usize;

    name: []const u8 = &.{},
    count: usize = 0,
};

pub const Course = struct {
    const Self = @This();
    pub const Ix = usize;

    name: []const u8 = &.{},
    hours: usize = 0,
    classes: []Class.Ix = &.{},
};

pub const Section = struct {
    const Self = @This();
};

pub const Lesson = struct {
    const Self = @This();
    pub const Ix = usize;

    course_ix: Course.Ix = 0,
    hour: usize = 0,
};

pub const Hour = struct {
    const Self = @This();
};

pub const Constraint = struct {
    const Self = @This();
};
