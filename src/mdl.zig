const std = @import("std");
const rubr = @import("rubr.zig");

pub const Error = error{
    WrongStructure,
};

pub const Count = struct {
    classes: usize = 0,
    groups: usize = 0,
    courses: usize = 0,
};

pub const Model = struct {
    const Self = @This();

    a: std.mem.Allocator,

    classes: []Class = &.{},
    groups: []Group = &.{},
    courses: []Course = &.{},

    pub fn init(a: std.mem.Allocator) Self {
        return Model{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        for (self.classes) |class|
            self.a.free(class.courses);
        self.a.free(self.classes);

        self.a.free(self.groups);
        self.a.free(self.courses);
    }
    pub fn alloc(self: *Self, count: Count) !void {
        self.classes = try self.a.alloc(Class, count.classes);
        @memset(self.classes, .{});
        self.groups = try self.a.alloc(Group, count.groups);
        @memset(self.groups, .{});
        self.courses = try self.a.alloc(Course, count.courses);
        @memset(self.courses, .{});
    }

    pub fn findGap(self: Self, schedule: *const Schedule) ?Gap {
        for (self.groups) |group| {
            for (schedule.hour__classes, 0..) |mask, hour| {
                const intersection = group.classes.mask & mask.mask;
                if (intersection != 0 and intersection != group.classes.mask) {
                    // This is a gap
                    return Gap{ .hour = hour, .classes = ClassSet{ .mask = group.classes.mask - intersection } };
                }
            }
        }
        return null;
    }

    pub fn write(self: Self) !void {
        if (self.log.level(1)) |w| {
            for (self.groups, 0..) |group, _group_ix| {
                const group_ix = Group.Ix.init(_group_ix);

                var count: usize = 0;
                var it = group.classes.iterator();
                while (it.next()) |class_ix|
                    count += class_ix.cptr(self.classes).count;
                try w.print("Group '{s}' ({}):", .{ group.name, count });
                for (self.classes) |class| {
                    if (class.group.eql(group_ix))
                        try w.print(" {s} ({})", .{ class.name, class.count });
                }
                try w.print("\n", .{});
            }
            for (self.courses) |course| {
                try w.print("Course '{s}' ({}h): ", .{ course.name, course.hours });
                var it = course.classes.iterator();
                while (it.next()) |class_ix|
                    try w.print(" {s}", .{class_ix.cptr(self.classes).name});
                try w.print("\n", .{});
            }
        }
    }
};

pub const Schedule = struct {
    const Self = @This();

    a: std.mem.Allocator,
    hour__class__lesson: [][]?Lesson = &.{},
    hour__classes: []ClassSet = &.{},

    pub fn init(a: std.mem.Allocator) Self {
        return Self{ .a = a };
    }
    pub fn deinit(self: *Self) void {
        for (self.hour__class__lesson) |e|
            self.a.free(e);
        self.a.free(self.hour__class__lesson);
        self.a.free(self.hour__classes);
    }
    pub fn copy(self: Self) !Self {
        var ret = Self.init(self.a);
        errdefer ret.deinit();
        ret.hour__class__lesson = try ret.a.alloc([]?Lesson, self.hour__class__lesson.len);
        for (ret.hour__class__lesson, 0..) |*dst, ix| {
            const src = self.hour__class__lesson[ix];
            dst.* = try ret.a.alloc(?Lesson, src.len);
            std.mem.copyForwards(?Lesson, dst.*, src);
        }
        ret.hour__classes = try ret.a.alloc(ClassSet, self.hour__classes.len);
        std.mem.copyForwards(ClassSet, ret.hour__classes, self.hour__classes);
        return ret;
    }
    pub fn alloc(self: *Self, hours: usize, classes: usize) !void {
        self.hour__class__lesson = try self.a.alloc([]?Lesson, hours);
        for (self.hour__class__lesson) |*class__lesson| {
            class__lesson.* = try self.a.alloc(?Lesson, classes);
            @memset(class__lesson.*, null);
        }
        self.hour__classes = try self.a.alloc(ClassSet, hours);
        @memset(self.hour__classes, ClassSet{});
    }
    pub fn assign(self: *Self, other: Self) !void {
        if (other.hour__class__lesson.len != self.hour__class__lesson.len)
            return Error.WrongStructure;
        for (self.hour__class__lesson, 0..) |dst, ix| {
            const src = other.hour__class__lesson[ix];
            std.mem.copyForwards(?Lesson, dst, src);
        }
        std.mem.copyForwards(ClassSet, self.hour__classes, other.hour__classes);
    }

    pub fn isEmpty(self: Schedule, hour: usize) bool {
        return self.hour__classes[hour].mask == 0;
    }

    pub fn isFree(self: Schedule, hour: usize, lesson: Lesson) bool {
        const class__lesson = self.hour__class__lesson[hour];

        var it = lesson.classes.iterator();
        while (it.next()) |class_ix| {
            if (class__lesson[class_ix.ix]) |blocking_lesson| {
                _ = blocking_lesson;
                return false;
            }
        }

        return true;
    }

    pub fn updateLesson(self: *Schedule, hour: usize, lesson: Lesson, set: bool) void {
        const class__lesson = self.hour__class__lesson[hour];
        var it = lesson.classes.iterator();

        if (set) {
            while (it.next()) |class_ix|
                class__lesson[class_ix.ix] = lesson;
            self.hour__classes[hour].mask |= lesson.classes.mask;
        } else {
            while (it.next()) |class_ix|
                class__lesson[class_ix.ix] = null;
            self.hour__classes[hour].mask &= ~lesson.classes.mask;
        }
    }

    pub fn write(self: Self, writer: rubr.log.Log.Writer, model: Model) !void {
        var max_width: usize = 0;
        for (self.hour__class__lesson) |class__lesson| {
            for (class__lesson) |maybe_lesson| {
                if (maybe_lesson) |lesson| {
                    const course = lesson.course.cptr(model.courses);
                    max_width = @max(max_width, course.name.len + 2 + 2);
                }
            }
        }

        const Line = struct {
            const My = @This();
            a: std.mem.Allocator,
            width: usize,
            w: rubr.log.Log.Writer,
            buf: []u8 = &.{},
            fn init(a: std.mem.Allocator, width: usize, w: rubr.log.Log.Writer) !My {
                try w.print("|", .{});
                return My{ .a = a, .width = width, .w = w, .buf = try a.alloc(u8, width) };
            }
            fn deinit(my: *My) void {
                my.w.print("\n", .{}) catch {};
                my.a.free(my.buf);
            }
            fn print(my: *My, comptime fmt: []const u8, options: anytype) void {
                for (my.buf) |*ch|
                    ch.* = ' ';
                _ = std.fmt.bufPrint(my.buf, fmt, options) catch {};
                my.w.print(" {s} |", .{my.buf}) catch {};
            }
        };

        {
            var line = try Line.init(self.a, max_width, writer);
            defer line.deinit();
            line.print("", .{});
            for (model.groups) |group| {
                var it = group.classes.iterator();
                while (it.next()) |class_ix| {
                    const class = class_ix.cptr(model.classes);
                    line.print("{s} {}", .{ class.name, class.group.ix });
                }
            }
        }

        for (self.hour__class__lesson, 0..) |class__lesson, hour_ix| {
            var line = try Line.init(self.a, max_width, writer);
            defer line.deinit();
            // _ = hour_ix;
            line.print("{}", .{hour_ix});
            for (model.groups) |group| {
                var it = group.classes.iterator();
                while (it.next()) |class_ix| {
                    const maybe_lesson = class__lesson[class_ix.ix];
                    if (maybe_lesson) |lesson| {
                        const course = lesson.course.cptr(model.courses);
                        line.print("{s}-{}-{}", .{ course.name, lesson.section, lesson.hour });
                    } else {
                        line.print("", .{});
                    }
                }
            }
        }
    }
};

pub const Class = struct {
    const Self = @This();
    pub const Ix = rubr.idx.Ix(Class);

    name: []const u8 = &.{},
    group: Group.Ix = .{},
    count: usize = 0,
    courses: []Course.Ix = &.{},
};

pub const ClassSet = struct {
    const Self = @This();

    mask: u64 = 0,

    pub fn add(self: *Self, ix: usize) void {
        self.mask |= @as(u64, 1) << @intCast(ix);
    }

    pub fn first(self: Self, classes: []const Class) *const Class {
        const ix = @ctz(self.mask);
        return &classes[ix];
    }

    pub const Iterator = struct {
        const My = @This();
        mask: u64 = 0,
        pub fn next(my: *My) ?Class.Ix {
            if (my.mask == 0)
                return null;
            const ix = @ctz(my.mask);
            my.mask -= @as(u64, 1) << @intCast(ix);
            return Class.Ix.init(ix);
        }
    };
    pub fn iterator(self: Self) Iterator {
        return Iterator{ .mask = self.mask };
    }
};

pub const Group = struct {
    const Self = @This();
    pub const Ix = rubr.idx.Ix(Group);

    name: []const u8 = &.{},
    classes: ClassSet = .{},
};

pub const Course = struct {
    const Self = @This();
    pub const Ix = rubr.idx.Ix(Course);

    name: []const u8 = &.{},
    hours: usize = 0,
    classes: ClassSet = .{},
};

pub const Lesson = struct {
    const Self = @This();

    course: Course.Ix,
    classes: ClassSet = .{},
    students: usize = 0, // &todo remove this field
    section: usize = 0, // A Course is split into different sections, each section respecting the classroom_capacity
    hour: usize = 0,
};

pub const Hour = struct {
    const Self = @This();

    classes: ClassSet = .{},
};

pub const Constraint = struct {
    const Self = @This();
};

pub const Gap = struct {
    const Self = @This();

    hour: usize = 0,
    classes: ClassSet = .{},
};
