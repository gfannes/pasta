const std = @import("std");
const cfg = @import("cfg.zig");
const csv = @import("csv.zig");
const mdl = @import("mdl.zig");

pub const Error = error{
    FormatError,
};

pub const App = struct {
    const Self = @This();

    a: std.mem.Allocator,
    hours_per_week: usize = 0,
    classroom_capacity: usize = 0,
    lesson_table: csv.Table,
    count: mdl.Count = .{},
    model: mdl.Model,

    pub fn init(a: std.mem.Allocator) Self {
        return Self{
            .a = a,
            // &todo: set to 32
            .hours_per_week = 7,
            // &todo: set to 26
            .classroom_capacity = 10,
            .lesson_table = csv.Table.init(a),
            .model = mdl.Model.init(a),
        };
    }
    pub fn deinit(self: *Self) void {
        self.lesson_table.deinit();
        self.model.deinit();
    }

    pub fn setup(self: *Self, config: cfg.Config) !void {
        try self.loadLessonTable(config.lesson_fp);
        self.determineCounts();
        try self.model.alloc(self.count);
        try self.loadData();
    }

    pub fn fit(self: Self) !?mdl.Schedule {
        var schedule = mdl.Schedule.init(self.a);
        try schedule.alloc(self.hours_per_week, self.count.classes);

        const all_lessons: []mdl.Lesson.Ix = try self.a.alloc(mdl.Lesson.Ix, self.model.lessons.len);
        for (all_lessons, 0..) |*lesson, ix|
            lesson.* = ix;
        defer self.a.free(all_lessons);

        const lessons_to_fit = self.deriveLessonsToFit(all_lessons);
        std.debug.print("Lessons to fit {any}\n", .{lessons_to_fit});

        if (self.fit_(all_lessons, &schedule))
            return schedule;

        schedule.deinit();
        return null;
    }

    fn fit_(self: Self, lessons: []mdl.Lesson.Ix, schedule: *mdl.Schedule) bool {
        if (lessons.len == 0)
            return true;

        const lesson_ix = lessons[0];
        const lesson = &self.model.lessons[lesson_ix];
        const course = &self.model.courses[lesson.course_ix];
        std.debug.print("Fitting Lesson {} {any}\n", .{ lesson_ix, lesson });
        for (0..self.hours_per_week) |hour| {
            if (schedule.isFree(hour, course)) {
                std.debug.print("\tCould fit Course {} in Hour {}\n", .{ lesson.course_ix, hour });

                schedule.insertLesson(hour, course, lesson_ix);

                if (self.fit_(lessons[1..], schedule))
                    return true;

                // Recursive fit_() failed: erase lesson and continue the search
                schedule.insertLesson(hour, course, null);
            }
        }

        schedule.write(self.model);
        std.debug.print("Could not find a fit\n", .{});
        return false;
    }

    fn deriveLessonsToFit(self: Self, all_lessons: []mdl.Lesson.Ix) []mdl.Lesson.Ix {
        var ret = all_lessons;
        ret.len = 0;
        for (self.model.courses, 0..) |_, course_ix| {
            var maybe_group_ix: ?mdl.Group.Ix = null;
            for (self.model.classes) |class| {
                if (std.mem.indexOfScalar(mdl.Course.Ix, class.courses, course_ix)) |_| {
                    if (maybe_group_ix) |group_ix| {
                        if (group_ix != class.group) {
                            for (all_lessons[ret.len..], ret.len..) |lesson_ix, ix| {
                                const lesson = &self.model.lessons[lesson_ix];
                                if (lesson.course_ix == course_ix) {
                                    ret.len += 1;
                                    std.mem.swap(mdl.Lesson.Ix, &ret[ret.len - 1], &all_lessons[ix]);
                                }
                            }
                            break;
                        }
                    }
                    maybe_group_ix = class.group;
                }
            }
        }
        return ret;
    }

    fn loadLessonTable(self: *Self, fp: []const u8) !void {
        try self.lesson_table.loadFromFile(fp);
    }

    fn determineCounts(self: *Self) void {
        self.count = .{};
        for (self.lesson_table.rows[0][2..]) |cell| {
            if (std.mem.eql(u8, cell.str, "class"))
                self.count.classes += 1;
        }
        for (self.lesson_table.rows[2..]) |row| {
            if (std.mem.eql(u8, row[0].str, "group"))
                self.count.groups += 1;
            if (std.mem.eql(u8, row[0].str, "course")) {
                self.count.courses += 1;
                if (row[2].int) |hours| {
                    self.count.lessons += @intCast(hours);
                } else {
                    std.debug.print("Error: could not find hour count for course '{s}'\n", .{row[1].str});
                }
            }
        }

        std.debug.print("count: {}\n", .{self.count});
    }

    fn loadData(self: *Self) !void {
        var class__col = try self.a.alloc(usize, self.count.classes);
        defer self.a.free(class__col);
        {
            var class_ix: usize = 0;
            for (self.lesson_table.rows[0], 0..) |cell, col_ix| {
                if (std.mem.eql(u8, cell.str, "class")) {
                    defer class_ix += 1;
                    class__col[class_ix] = col_ix;
                }
            }
            std.debug.assert(class_ix == self.count.classes);
        }

        var group__row = try self.a.alloc(usize, self.count.groups);
        defer self.a.free(group__row);
        var course__row = try self.a.alloc(usize, self.count.courses);
        defer self.a.free(course__row);
        {
            var group_ix: usize = 0;
            var course_ix: usize = 0;
            for (self.lesson_table.rows[2..], 2..) |row, row_ix| {
                if (std.mem.eql(u8, row[0].str, "group")) {
                    defer group_ix += 1;
                    group__row[group_ix] = row_ix;
                }
                if (std.mem.eql(u8, row[0].str, "course")) {
                    defer course_ix += 1;
                    course__row[course_ix] = row_ix;
                }
            }
            std.debug.assert(group_ix == self.count.groups);
            std.debug.assert(course_ix == self.count.courses);
        }

        for (class__col, 0..) |col_ix, class_ix| {
            const class = &self.model.classes[class_ix];
            class.name = self.lesson_table.rows[1][col_ix].str;
            if (self.lesson_table.rows[2][col_ix].int) |count| {
                class.count = @intCast(count);
            } else {
                std.debug.print("Error: could not find Class size for '{s}'\n", .{class.name});
            }

            var course_count: usize = 0;
            for (course__row) |row_ix| {
                if (self.lesson_table.rows[row_ix][col_ix].int) |int| {
                    if (int != 1) {
                        std.debug.print("Error: please use '1' to indicate that a Class follows a Course\n", .{});
                        return Error.FormatError;
                    }
                    course_count += 1;
                }
            }
            class.courses = try self.a.alloc(mdl.Course.Ix, course_count);
            class.courses.len = 0;
        }

        var group_ix: usize = 0;
        var course_ix: usize = 0;
        var lesson_ix: usize = 0;
        for (self.lesson_table.rows[2..]) |row| {
            if (std.mem.eql(u8, row[0].str, "group")) {
                defer group_ix += 1;
                const group = &self.model.groups[group_ix];
                group.name = row[1].str;
                for (class__col, 0..) |col_ix, class_ix| {
                    if (row[col_ix].int) |int| {
                        if (int != 1) {
                            std.debug.print("Error: please use '1' to indicate that a Class belongs to a Group, not '{s}'\n", .{row[col_ix].str});
                            return Error.FormatError;
                        }
                        const class = &self.model.classes[class_ix];
                        class.group = group_ix;
                        group.count += class.count;
                    }
                }
            }
            if (std.mem.eql(u8, row[0].str, "course")) {
                defer course_ix += 1;
                const course = &self.model.courses[course_ix];
                course.name = row[1].str;
                course.hours = @intCast(row[2].int orelse unreachable);
                for (0..course.hours) |hour| {
                    defer lesson_ix += 1;
                    self.model.lessons[lesson_ix] = mdl.Lesson{ .course_ix = course_ix, .hour = hour };
                }

                var class_count: usize = 0;
                for (class__col, 0..) |col_ix, class_ix| {
                    if (row[col_ix].int) |int| {
                        if (int != 1) {
                            std.debug.print("Error: please use '1' to indicate that a Class belongs to a Group, not '{s}'\n", .{row[col_ix].str});
                            return Error.FormatError;
                        }
                        class_count += 1;
                        const class = &self.model.classes[class_ix];
                        class.courses.len += 1;
                        class.courses[class.courses.len - 1] = course_ix;
                    }
                }

                course.classes = try self.a.alloc(mdl.Class.Ix, class_count);
                course.classes.len = 0;
                for (class__col, 0..) |col_ix, class_ix| {
                    if (row[col_ix].int) |int| {
                        if (int != 1) {
                            std.debug.print("Error: please use '1' to indicate that a Class belongs to a Group, not '{s}'\n", .{row[col_ix].str});
                            return Error.FormatError;
                        }
                        course.classes.len += 1;
                        course.classes[course.classes.len - 1] = class_ix;
                    }
                }
            }
        }
    }
};
