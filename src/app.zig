const std = @import("std");
const cfg = @import("cfg.zig");
const csv = @import("csv.zig");
const mdl = @import("mdl.zig");

pub const Error = error{
    FormatError,
    GroupMismatch,
    TooManyClasses,
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
            .hours_per_week = 40,
            // &todo: set to 26
            .classroom_capacity = 26,
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
        self.count = deriveCounts(self.lesson_table);
        try self.model.alloc(self.count);
        try self.loadData();
        try self.splitCourses();
    }

    pub fn fit(self: Self) !?mdl.Schedule {
        var schedule = mdl.Schedule.init(self.a);
        try schedule.alloc(self.hours_per_week, self.count.classes);

        const all_lessons: []mdl.Lesson.Ix = try self.a.alloc(mdl.Lesson.Ix, self.model.lessons.len);
        for (all_lessons, 0..) |*lesson, ix|
            lesson.* = mdl.Lesson.Ix.init(ix);
        defer self.a.free(all_lessons);

        const lessons_to_fit = self.deriveLessonsToFit(all_lessons);
        std.debug.print("Lessons to fit", .{});
        for (lessons_to_fit) |lesson|
            std.debug.print(" {}", .{lesson.ix});
        std.debug.print("\n", .{});

        if (self.fit_(lessons_to_fit, &schedule))
            return schedule;

        schedule.deinit();
        return null;
    }

    fn fit_(self: Self, lessons: []mdl.Lesson.Ix, schedule: *mdl.Schedule) bool {
        if (lessons.len == 0)
            return true;

        const lesson_ix = lessons[0];
        const lesson = lesson_ix.cptr(self.model.lessons);
        const section = lesson.section.cptr(self.model.sections);
        for (0..self.hours_per_week) |hour| {
            if (schedule.isFree(hour, section)) {
                // std.debug.print("\tCould fit Course {} in Hour {}\n", .{ lesson.course_ix, hour });

                schedule.insertLesson(hour, section, lesson_ix);

                if (self.fit_(lessons[1..], schedule))
                    return true;

                // Recursive fit_() failed: erase lesson and continue the search
                schedule.insertLesson(hour, section, null);
            }
        }

        // schedule.write(self.model);
        // std.debug.print("Could not find a fit\n", .{});
        return false;
    }

    fn deriveLessonsToFit(self: Self, all_lessons: []mdl.Lesson.Ix) []mdl.Lesson.Ix {
        var ret = all_lessons;
        ret.len = 0;
        for (self.model.sections, 0..) |_, _section_ix| {
            const section_ix = mdl.Section.Ix.init(_section_ix);

            var maybe_group_ix: ?mdl.Group.Ix = null;
            for (self.model.classes) |class| {
                var class_has_course: bool = false;
                for (class.courses) |course| {
                    if (course.eql(section_ix.cptr(self.model.sections).course)) {
                        class_has_course = true;
                        break;
                    }
                }

                if (class_has_course) {
                    if (maybe_group_ix) |group_ix| {
                        if (!group_ix.eql(class.group)) {
                            // This Section is given to different class groups: all its Lessons must be fit
                            for (all_lessons[ret.len..], ret.len..) |lesson_ix, ix| {
                                const lesson = lesson_ix.cptr(self.model.lessons);
                                if (lesson.section.eql(section_ix)) {
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

    fn deriveCounts(lesson_table: csv.Table) mdl.Count {
        var count = mdl.Count{};

        for (lesson_table.rows[0][3..], 3..) |cell, ix| {
            if (std.mem.eql(u8, cell.str, "class")) {
                if (lesson_table.rows[2][ix].int) |int| {
                    if (int > 0)
                        count.classes += 1;
                }
            }
        }
        for (lesson_table.rows[2..]) |row| {
            if (std.mem.eql(u8, row[0].str, "group"))
                count.groups += 1;
            if (std.mem.eql(u8, row[0].str, "course")) {
                count.courses += 1;
                if (row[2].int == null)
                    std.debug.print("Error: could not find hour count for course '{s}'\n", .{row[1].str});
            }
        }

        std.debug.print("count: {}\n", .{count});
        return count;
    }

    fn loadData(self: *Self) !void {
        if (self.count.classes > 64)
            return Error.TooManyClasses;

        var class__col = try self.a.alloc(usize, self.count.classes);
        defer self.a.free(class__col);
        {
            var class_ix: usize = 0;
            for (self.lesson_table.rows[0][3..], 3..) |cell, col_ix| {
                if (std.mem.eql(u8, cell.str, "class")) {
                    if (self.lesson_table.rows[2][col_ix].int) |int| {
                        if (int > 0) {
                            defer class_ix += 1;
                            class__col[class_ix] = col_ix;
                        }
                    }
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
            for (course__row, 0..) |row_ix, course_ix| {
                if (self.lesson_table.rows[row_ix][col_ix].int) |int| {
                    if (int != 1 and int != 0) {
                        const course = &self.model.courses[course_ix];
                        std.debug.print("Error: please use a '1' to indicate that Class '{s}' follows Course '{s}'\n", .{ class.name, course.name });
                        return Error.FormatError;
                    }
                    course_count += @intCast(int);
                }
            }
            class.courses = try self.a.alloc(mdl.Course.Ix, course_count);
            class.courses.len = 0;
        }

        var group_ix: usize = 0;
        var course_ix: usize = 0;
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
                        group.class_mask |= @as(u64, 1) << @intCast(class_ix);
                        const class = &self.model.classes[class_ix];
                        class.group = mdl.Group.Ix.init(group_ix);
                    }
                }
            }
            if (std.mem.eql(u8, row[0].str, "course")) {
                defer course_ix += 1;
                const course = &self.model.courses[course_ix];
                course.name = row[1].str;
                course.hours = @intCast(row[2].int orelse unreachable);

                var class_count: usize = 0;
                for (class__col, 0..) |col_ix, class_ix| {
                    if (row[col_ix].int) |int| {
                        switch (int) {
                            0 => {},
                            1 => {
                                course.class_mask |= @as(u64, 1) << @intCast(class_ix);
                                class_count += 1;
                                const class = &self.model.classes[class_ix];
                                class.courses.len += 1;
                                class.courses[class.courses.len - 1] = mdl.Course.Ix.init(course_ix);
                            },
                            else => {
                                const class_name = self.lesson_table.rows[1][col_ix].str;
                                std.debug.print("Error: please use '0/1' to indicate that Class '{s}' follows Course '{s}', not '{s}'\n", .{ class_name, course.name, row[col_ix].str });
                                return Error.FormatError;
                            },
                        }
                    }
                }

                course.classes = try self.a.alloc(mdl.Class.Ix, class_count);
                course.classes.len = 0;
                for (class__col, 0..) |col_ix, class_ix| {
                    if (row[col_ix].int) |int| {
                        switch (int) {
                            0 => {},
                            1 => {
                                course.classes.len += 1;
                                course.classes[course.classes.len - 1] = mdl.Class.Ix.init(class_ix);
                            },
                            else => {
                                const class_name = self.lesson_table.rows[1][col_ix].str;
                                std.debug.print("Error: please use '0/1' to indicate that Class '{s}' follows Course '{s}', not '{s}'\n", .{ class_name, course.name, row[col_ix].str });
                                return Error.FormatError;
                            },
                        }
                    }
                }
            }
        }

        for (self.model.groups, 0..) |*group, gix| {
            var count: usize = 0;
            for (self.model.classes) |class| {
                if (class.group.ix == gix)
                    count += 1;
            }
            group.classes = try self.a.alloc(mdl.Class.Ix, count);
            group.classes.len = 0;
            for (self.model.classes, 0..) |class, class_ix| {
                if (class.group.ix == gix) {
                    group.classes.len += 1;
                    group.classes[group.classes.len - 1] = mdl.Class.Ix.init(class_ix);
                }
            }
        }
    }

    fn splitCourses(self: *Self) !void {
        var sections = std.ArrayList(mdl.Section).init(self.a);
        defer sections.deinit();

        for (self.model.courses, 0..) |*course, course_ix| {
            const sections_start = sections.items.len;

            // Distribute classes over Sections based on Class.group
            for (course.classes) |class_ix| {
                const class = class_ix.cptr(self.model.classes);

                var could_add: bool = false;
                for (sections.items[sections_start..]) |*section| {
                    const first_class = section.classes[0].cptr(self.model.classes);
                    if (first_class.group.eql(class.group)) {
                        section.class_mask |= @as(u64, 1) << @intCast(class_ix.ix);
                        section.students += class.count;
                        section.classes.len += 1;
                        section.classes[section.classes.len - 1] = class_ix;
                        could_add = true;
                    }
                }
                if (!could_add) {
                    var section = mdl.Section{ .course = mdl.Course.Ix.init(course_ix), .students = class.count, .classes = try self.a.alloc(mdl.Class.Ix, course.classes.len), .class_mask = @as(u64, 1) << @intCast(class_ix.ix) };
                    section.classes.len = 1;
                    section.classes[section.classes.len - 1] = class_ix;
                    try sections.append(section);
                }
            }

            // &todo Merge small Sections into larger ones
        }

        self.model.sections = try self.a.alloc(mdl.Section, sections.items.len);
        std.mem.copyForwards(mdl.Section, self.model.sections, sections.items);
        for (self.model.sections) |*section| {
            const orig_classes = section.classes;
            section.classes = try self.a.alloc(mdl.Class.Ix, orig_classes.len);
            std.mem.copyForwards(mdl.Class.Ix, section.classes, orig_classes);
        }

        for (sections.items) |*section| {
            section.classes.len = section.course.cptr(self.model.courses).classes.len;
            self.a.free(section.classes);
        }

        // Create Lessons
        var lesson_count: usize = 0;
        for (self.model.sections) |section| {
            const course = section.course.cptr(self.model.courses);
            lesson_count += course.hours;
        }
        self.model.lessons = try self.a.alloc(mdl.Lesson, lesson_count);
        var lesson_ix: usize = 0;
        for (self.model.sections, 0..) |section, section_ix| {
            const course = section.course.cptr(self.model.courses);
            for (0..course.hours) |hour| {
                defer lesson_ix += 1;
                self.model.lessons[lesson_ix] = mdl.Lesson{ .section = mdl.Section.Ix.init(section_ix), .hour = hour };
            }
        }
        std.debug.assert(lesson_ix == self.model.lessons.len);
    }
};
