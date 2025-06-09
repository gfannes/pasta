const std = @import("std");
const cfg = @import("cfg.zig");
const csv = @import("csv.zig");
const mdl = @import("mdl.zig");

pub const Error = error{
    FormatError,
    GroupMismatch,
    TooManyClasses,
    TooManySections,
    TooManyStudents,
    Stop,
};

pub const App = struct {
    const Self = @This();
    const FitData = struct {
        n: usize = 0,
        maybe_schedule: ?mdl.Schedule = null,
        maybe_unfit: ?usize = null,

        fn deinit(self: *FitData) void {
            if (self.maybe_schedule) |*schedule|
                schedule.deinit();
        }

        fn store(self: *FitData, unfit: usize, schedule: mdl.Schedule) !bool {
            if (self.maybe_unfit) |uf| {
                if (unfit < uf) {
                    std.debug.print("Found better fit, still {} Lessons not fitted\n", .{unfit});
                    self.maybe_unfit = unfit;
                    try (self.maybe_schedule orelse unreachable).assign(schedule);
                    return true;
                }
            } else {
                self.maybe_unfit = unfit;
                self.maybe_schedule = try schedule.copy();
                return true;
            }
            return false;
        }
    };

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
            .hours_per_week = 20,
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
        try self.createLessons();

        var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
        const rng = prng.random();
        rng.shuffle(mdl.Lesson, self.model.lessons);
    }

    pub fn fit(self: Self) !?mdl.Schedule {
        var schedule = mdl.Schedule.init(self.a);
        errdefer schedule.deinit();
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

        var fitData = FitData{};
        defer fitData.deinit();
        if (try self.fit_(lessons_to_fit, &schedule, &fitData))
            return schedule;

        schedule.deinit();
        return null;
    }

    fn fit_(self: Self, lessons: []mdl.Lesson.Ix, schedule: *mdl.Schedule, fitData: *FitData) !bool {
        if (try fitData.store(lessons.len, schedule.*)) {
            try schedule.write(self.model);
        }

        if (lessons.len == 0)
            return true;

        const doLog: bool = false;

        // if (fitData.n.* > 20)
        //     return Error.Stop;
        defer fitData.n += 1;

        if (self.model.findGap(schedule)) |gap| {
            // There is a gap to fill for some Group: fill this first
            // 1. Find Lesson that _fills the complete Gap_
            // 2. Find Lesson that _fills something from the Gap_

            if (doLog) {
                std.debug.print("{} Filling Gap for hour {} for", .{ lessons.len, gap.hour });
                var it = gap.classes.iterator();
                while (it.next()) |class_ix|
                    std.debug.print(" {s}", .{class_ix.cptr(self.model.classes).name});
                std.debug.print("\n", .{});
            }

            const FillStrategy = enum {
                Complete,
                Partial,
            };
            for (&[_]FillStrategy{ FillStrategy.Complete, FillStrategy.Partial }) |fill_strategy| {
                if (doLog)
                    std.debug.print("\t{any}\n", .{fill_strategy});
                // Sections that are already tested and could not be fit
                var already_tested_mask: u128 = 0;

                for (lessons) |*lesson_ix| {
                    const lesson = lesson_ix.cptr(self.model.lessons);
                    const section_mask = @as(u128, 1) << @intCast(lesson.section.ix);

                    const section = lesson.section.cptr(self.model.sections);
                    const course = section.course.cptr(self.model.courses);

                    if (section_mask & already_tested_mask != 0) {
                        if (doLog)
                            std.debug.print("\tNo need to test {s}-{}-{}\n", .{ course.name, section.n, lesson.hour });
                        continue;
                    }

                    const section_fits_in_schedule = section.classes.mask & schedule.hour__classes[gap.hour].mask == 0;
                    if (!section_fits_in_schedule)
                        // This Lesson does not fit for the given Hour
                        continue;

                    const section_fills_gap = switch (fill_strategy) {
                        FillStrategy.Complete => section.classes.mask & gap.classes.mask == gap.classes.mask,
                        FillStrategy.Partial => section.classes.mask & gap.classes.mask != 0,
                    };
                    if (section_fills_gap) {
                        schedule.insertLesson(gap.hour, section, lesson_ix.*);
                        if (doLog) {
                            std.debug.print("\tFitted Lesson {s}-{}-{} for {}\n", .{ course.name, section.n, lesson.hour, gap.hour });
                            try schedule.write(self.model);
                        }
                        std.mem.swap(mdl.Lesson.Ix, lesson_ix, &lessons[0]);

                        if (try self.fit_(lessons[1..], schedule, fitData))
                            return true;

                        already_tested_mask |= section_mask;

                        // Recursive fit_() failed: erase lesson and continue the search
                        std.mem.swap(mdl.Lesson.Ix, lesson_ix, &lessons[0]);
                        if (doLog)
                            std.debug.print("\tRemoving {s}-{}-{}\n", .{ course.name, section.n, lesson.hour });
                        schedule.insertLesson(gap.hour, section, null);
                    }
                }
            }
            if (doLog) {
                std.debug.print("\tCould not fill Gap\n", .{});
                try schedule.write(self.model);
            }
        } else {
            // There is no Gap: fit the first Lesson, only fit it on an empty Hour once
            const lesson_ix = lessons[0];
            const lesson = lesson_ix.cptr(self.model.lessons);
            const section = lesson.section.cptr(self.model.sections);
            const course = section.course.cptr(self.model.courses);

            var tested_empty_hour: bool = false;
            for (0..self.hours_per_week) |hour| {
                if (schedule.isEmpty(hour)) {
                    if (tested_empty_hour)
                        continue;
                    tested_empty_hour = true;
                } else if (!schedule.isFree(hour, section)) {
                    continue;
                }

                schedule.insertLesson(hour, section, lesson_ix);
                if (doLog) {
                    std.debug.print("{} Placed Lesson {s}-{}-{} for hour {}\n", .{ lessons.len, course.name, section.n, lesson.hour, hour });
                    try schedule.write(self.model);
                }

                if (try self.fit_(lessons[1..], schedule, fitData))
                    return true;

                if (doLog)
                    std.debug.print("\tRemoving {s}-{}-{}\n", .{ course.name, section.n, lesson.hour });
                schedule.insertLesson(hour, section, null);

                // We try to fit a Lesson only in one place, for now
                // break;
            }
        }

        // schedule.write(self.model);
        // std.debug.print("Could not find a fit\n", .{});
        return false;
    }

    fn deriveLessonsToFit(self: Self, all_lessons: []mdl.Lesson.Ix) []mdl.Lesson.Ix {
        var ret = all_lessons;
        ret.len = 0;

        for (all_lessons) |*lesson_ix| {
            var lesson_is_for_one_group: bool = false;
            const lesson = lesson_ix.cptr(self.model.lessons);
            const section = lesson.section.cptr(self.model.sections);
            for (self.model.groups) |group| {
                if (group.classes.mask == section.classes.mask) {
                    lesson_is_for_one_group = true;
                    break;
                }
            }

            if (!lesson_is_for_one_group) {
                ret.len += 1;
                std.mem.swap(mdl.Lesson.Ix, &ret[ret.len - 1], lesson_ix);
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
                        group.classes.add(class_ix);
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
                                course.classes.add(class_ix);
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
            }
        }
    }

    fn splitCourses(self: *Self) !void {
        var sections = std.ArrayList(mdl.Section).init(self.a);
        defer sections.deinit();

        for (self.model.courses, 0..) |*course, course_ix| {
            if (false) {
                // Create Section per Group
                const sections_start = sections.items.len;
                var n: usize = 0;
                for (self.model.groups) |group| {
                    const intersection = course.classes.mask & group.classes.mask;
                    if (intersection != 0) {
                        defer n += 1;

                        var section = mdl.Section{ .course = mdl.Course.Ix.init(course_ix), .n = n, .classes = mdl.ClassSet{ .mask = intersection } };
                        var it = section.classes.iterator();
                        while (it.next()) |class_ix| {
                            const class = class_ix.cptr(self.model.classes);
                            section.students += class.count;
                        }
                        try sections.append(section);
                    }
                }

                while (true) {
                    const my_sections = sections.items[sections_start..];
                    if (my_sections.len < 2)
                        break;

                    const Fn = struct {
                        pub fn call(_: void, a: mdl.Section, b: mdl.Section) bool {
                            return a.students > b.students;
                        }
                    };
                    std.sort.block(mdl.Section, my_sections, {}, Fn.call);
                    const small = &my_sections[my_sections.len - 1];
                    const large = &my_sections[my_sections.len - 2];
                    if (small.students + large.students > self.classroom_capacity)
                        break;

                    large.students += small.students;
                    large.classes.mask |= small.classes.mask;

                    try sections.resize(sections.items.len - 1);
                }
            } else {
                // Create only a single Section per Course
                var section = mdl.Section{ .course = mdl.Course.Ix.init(course_ix), .n = 0, .classes = course.classes };
                var it = section.classes.iterator();
                while (it.next()) |class_ix| {
                    const class = class_ix.cptr(self.model.classes);
                    section.students += class.count;
                }
                try sections.append(section);
            }
        }

        if (sections.items.len > 128)
            return Error.TooManySections;

        for (sections.items) |section| {
            if (section.students > self.classroom_capacity) {
                const course = section.course.cptr(self.model.courses);
                std.debug.print("Too many students for {s}-{}: {} (max is {})\n", .{ course.name, section.n, section.students, self.classroom_capacity });
                return Error.TooManyStudents;
            }
        }

        self.model.sections = try self.a.alloc(mdl.Section, sections.items.len);
        std.mem.copyForwards(mdl.Section, self.model.sections, sections.items);
    }

    pub fn createLessons(self: *Self) !void {
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
