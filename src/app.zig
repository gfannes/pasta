const std = @import("std");
const cfg = @import("cfg.zig");
const csv = @import("csv.zig");
const mdl = @import("mdl.zig");
const rubr = @import("rubr.zig");

pub const Error = error{
    ExpectedInputFilepath,
    FormatError,
    GroupMismatch,
    TooManyClasses,
    TooManySections,
    TooManyStudents,
    Stop,
};

const Max = struct {
    const classes: usize = 64;
    const sections: usize = 128;
};

pub const Solution = struct {
    const Self = @This();

    schedule: mdl.Schedule,
    unfit: usize,
    pub fn deinit(self: *Self) void {
        self.schedule.deinit();
    }
};

pub const App = struct {
    const Self = @This();
    const FitData = struct {
        step: usize = 0,
        maybe_solution: ?Solution = null,

        fn deinit(self: *FitData) void {
            if (self.maybe_solution) |*solution|
                solution.deinit();
        }

        fn store(self: *FitData, unfit: usize, schedule: mdl.Schedule) !bool {
            var is_better: bool = false;
            if (self.maybe_solution) |*solution| {
                if (unfit < solution.unfit) {
                    solution.unfit = unfit;
                    try solution.schedule.assign(schedule);
                    is_better = true;
                }
            } else {
                self.maybe_solution = Solution{ .schedule = try schedule.copy(), .unfit = unfit };
                is_better = true;
            }
            return is_better;
        }
    };

    a: std.mem.Allocator,
    log: *const rubr.log.Log,
    hours_per_week: usize = 0,
    classroom_capacity: usize = 0,
    lesson_table: csv.Table,
    count: mdl.Count = .{},
    max_steps: ?usize = null,
    model: mdl.Model,
    prng: std.Random.DefaultPrng,

    pub fn init(a: std.mem.Allocator, log: *const rubr.log.Log) Self {
        return Self{
            .a = a,
            .log = log,
            // &todo: set to 32
            .hours_per_week = 32,
            // &todo: set to 26
            .classroom_capacity = 26,
            .lesson_table = csv.Table.init(a),
            .model = mdl.Model.init(a),
            .prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp())),
        };
    }
    pub fn deinit(self: *Self) void {
        self.lesson_table.deinit();
        self.model.deinit();
    }

    pub fn setup(self: *Self, config: cfg.Config) !void {
        self.max_steps = config.max_steps;
        if (config.output_dir) |output_dir| {
            try std.fs.cwd().makePath(output_dir);
        }

        const input_fp = config.input_fp orelse {
            try self.log.err("Please specify an input file\n", .{});
            return Error.ExpectedInputFilepath;
        };
        try self.loadLessonTable(input_fp);

        self.count = try deriveCounts(self.lesson_table, self.log);
        try self.model.alloc(self.count);
        try self.loadData();
        try self.createLessons(SplitStrategy.Random);
    }

    pub fn fit(self: *Self) !?Solution {
        var schedule = mdl.Schedule.init(self.a);
        defer schedule.deinit();
        try schedule.alloc(self.hours_per_week, self.count.classes);

        const all_lessons = try self.a.dupe(mdl.Lesson, self.model.lessons);
        defer self.a.free(all_lessons);

        const lessons_to_fit = self.deriveLessonsToFit(all_lessons);
        if (self.log.level(1)) |w| {
            try w.print("Lessons to fit", .{});
            for (lessons_to_fit) |lesson| {
                const course = lesson.course.cptr(self.model.courses);
                try w.print("\t{s}-{}-{}\n", .{ course.name, lesson.section, lesson.hour });
            }
        }

        const rng = self.prng.random();
        rng.shuffle(mdl.Lesson, lessons_to_fit);

        var fitData = FitData{};
        defer fitData.deinit();
        if (self.fit_(lessons_to_fit, &schedule, &fitData)) |ok| {
            if (ok)
                try self.log.info("Found solution!\n", .{})
            else
                try self.log.info("Could not find solution\n", .{});
        } else |err| {
            switch (err) {
                Error.Stop => try self.log.info("Stopping search\n", .{}),
                else => {
                    try self.log.err("Something went wrong during search: {}\n", .{err});
                    return err;
                },
            }
        }

        if (fitData.maybe_solution) |solution| {
            defer fitData.maybe_solution = null;
            return solution;
        }

        return null;
    }

    fn fit_(self: Self, lessons: []mdl.Lesson, schedule: *mdl.Schedule, fitData: *FitData) !bool {
        if (try fitData.store(lessons.len, schedule.*)) {
            if (self.log.level(1)) |w| {
                try w.print("Found better fit, still {} Lessons not fitted\n", .{lessons.len});
                for (lessons) |lesson| {
                    const course = lesson.course.cptr(self.model.courses);
                    try w.print("\t{s}-{}-{}", .{ course.name, lesson.section, lesson.hour });
                    var it = course.classes.iterator();
                    while (it.next()) |class_ix|
                        try w.print(" {s}", .{class_ix.cptr(self.model.classes).name});
                    try w.print("\n", .{});
                }
                try schedule.write(w, self.model);
            }
        }

        if (lessons.len == 0)
            // No more lessons to fit: we are done and found a fitting solution
            return true;

        if (self.max_steps) |max_steps| {
            if (fitData.step >= max_steps)
                return Error.Stop;
        }
        fitData.step += 1;

        if (self.model.findGap(schedule)) |gap| {
            // There is a gap to fill for some Group: fill this first
            // 1. Find Lesson that _fills the complete Gap_
            // 2. Find Lesson that _fills something from the Gap_

            if (self.log.level(1)) |w| {
                try w.print("{} Filling Gap for hour {} for", .{ lessons.len, gap.hour });
                var it = gap.classes.iterator();
                while (it.next()) |class_ix|
                    try w.print(" {s}", .{class_ix.cptr(self.model.classes).name});
                try w.print("\n", .{});
            }

            const FillStrategy = enum {
                Complete,
                Partial,
            };
            for (&[_]FillStrategy{ FillStrategy.Complete, FillStrategy.Partial }) |fill_strategy| {
                if (self.log.level(1)) |w|
                    try w.print("\t{any}\n", .{fill_strategy});

                // Lessons that are already tested and could not be fit
                var already_tested_mask: u128 = 0;

                for (lessons) |*lesson| {
                    const section_mask = @as(u128, 1) << @intCast(lesson.section);

                    const course = lesson.course.cptr(self.model.courses);

                    if (section_mask & already_tested_mask != 0) {
                        if (self.log.level(1)) |w|
                            try w.print("\tNo need to test {s}-{}-{}\n", .{ course.name, lesson.section, lesson.hour });
                        continue;
                    }

                    const section_fits_in_schedule = lesson.classes.mask & schedule.hour__classes[gap.hour].mask == 0;
                    if (!section_fits_in_schedule)
                        // This Lesson does not fit for the given Hour
                        continue;

                    const section_fills_gap = switch (fill_strategy) {
                        FillStrategy.Complete => lesson.classes.mask & gap.classes.mask == gap.classes.mask,
                        FillStrategy.Partial => lesson.classes.mask & gap.classes.mask != 0,
                    };
                    if (section_fills_gap) {
                        schedule.updateLesson(gap.hour, lesson.*, true);
                        if (self.log.level(1)) |w| {
                            try w.print("\tFitted Lesson {s}-{}-{} for {}\n", .{ course.name, lesson.section, lesson.hour, gap.hour });
                            try schedule.write(w, self.model);
                        }
                        std.mem.swap(mdl.Lesson, lesson, &lessons[0]);

                        if (try self.fit_(lessons[1..], schedule, fitData))
                            return true;

                        already_tested_mask |= section_mask;

                        // Recursive fit_() failed: erase lesson and continue the search
                        std.mem.swap(mdl.Lesson, lesson, &lessons[0]);
                        if (self.log.level(1)) |w|
                            try w.print("\tRemoving {s}-{}-{}\n", .{ course.name, lesson.section, lesson.hour });
                        schedule.updateLesson(gap.hour, lesson.*, false);
                    }
                }
            }
            if (self.log.level(1)) |w| {
                try w.print("\tCould not fill Gap\n", .{});
                try schedule.write(w, self.model);
            }
        } else {
            // There is no Gap: fit the first Lesson, only fit it on an empty Hour once
            const lesson = lessons[0];
            const course = lesson.course.cptr(self.model.courses);

            var tested_empty_hour: bool = false;
            for (0..self.hours_per_week) |hour| {
                if (schedule.isEmpty(hour)) {
                    if (tested_empty_hour)
                        continue;
                    tested_empty_hour = true;
                } else if (!schedule.isFree(hour, lesson)) {
                    continue;
                }

                schedule.updateLesson(hour, lesson, true);
                if (self.log.level(1)) |w| {
                    try w.print("{} Placed Lesson {s}-{}-{} for hour {}\n", .{ lessons.len, course.name, lesson.section, lesson.hour, hour });
                    try schedule.write(w, self.model);
                }

                if (try self.fit_(lessons[1..], schedule, fitData))
                    return true;

                if (self.log.level(1)) |w|
                    try w.print("\tRemoving {s}-{}-{}\n", .{ course.name, lesson.section, lesson.hour });
                schedule.updateLesson(hour, lesson, false);

                // We try to fit a Lesson only in one place, for now
                // break;
            }
        }

        return false;
    }

    // Reorders all_lessons, placing the Lessons that require a fit at the front.
    // A slice to these Lessons is returned
    fn deriveLessonsToFit(self: Self, all_lessons: []mdl.Lesson) []mdl.Lesson {
        var ret = all_lessons;
        ret.len = 0;

        for (all_lessons) |*lesson| {
            var lesson_is_for_one_group: bool = false;
            for (self.model.groups) |group| {
                if (group.classes.mask == lesson.classes.mask) {
                    lesson_is_for_one_group = true;
                    break;
                }
            }

            if (!lesson_is_for_one_group) {
                ret.len += 1;
                std.mem.swap(mdl.Lesson, &ret[ret.len - 1], lesson);
            }
        }

        return ret;
    }

    fn loadLessonTable(self: *Self, fp: []const u8) !void {
        try self.lesson_table.loadFromFile(fp);
    }

    fn deriveCounts(lesson_table: csv.Table, log: *const rubr.log.Log) !mdl.Count {
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
                if (row[2].int == null) {
                    try log.err("Could not find hour count for course '{s}'\n", .{row[1].str});
                    return Error.FormatError;
                }
            }
        }

        return count;
    }

    fn loadData(self: *Self) !void {
        if (self.count.classes > Max.classes) {
            try self.log.err("You have {} classes while I can only handle {}\n", .{ self.count.classes, Max.classes });
            return Error.TooManyClasses;
        }

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
                try self.log.err("Could not find Class size for '{s}'\n", .{class.name});
                return Error.FormatError;
            }

            var course_count: usize = 0;
            for (course__row, 0..) |row_ix, course_ix| {
                if (self.lesson_table.rows[row_ix][col_ix].int) |int| {
                    if (int != 1 and int != 0) {
                        const course = &self.model.courses[course_ix];
                        try self.log.err("Please use a '1' to indicate that Class '{s}' follows Course '{s}'\n", .{ class.name, course.name });
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
                            try self.log.err("Please use '1' to indicate that a Class belongs to a Group, not '{s}'\n", .{row[col_ix].str});
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
                                try self.log.err("Please use '0/1' to indicate that Class '{s}' follows Course '{s}', not '{s}'\n", .{ class_name, course.name, row[col_ix].str });
                                return Error.FormatError;
                            },
                        }
                    }
                }
            }
        }
    }

    pub const SplitStrategy = enum {
        OneSection,
        PerGroup_MergeSmall,
        Random,
    };
    fn createLessons(self: *Self, splitStrategy: SplitStrategy) !void {
        // Split the Courses into single Lessons, making sure they do not exceed the classroom_capacity
        var single_lessons = std.ArrayList(mdl.Lesson).init(self.a);
        defer single_lessons.deinit();
        {
            for (self.model.courses, 0..) |*course, course_ix| {
                if (course.classes.mask == 0)
                    // Nobody follows this Course
                    continue;
                if (course.hours == 0)
                    // Empty Course
                    continue;

                switch (splitStrategy) {
                    SplitStrategy.OneSection => {
                        // Create only a single Lesson per Course
                        var students: usize = 0;
                        var it = course.classes.iterator();
                        while (it.next()) |class_ix| {
                            const class = class_ix.cptr(self.model.classes);
                            students += class.count;
                        }
                        try single_lessons.append(mdl.Lesson{
                            .course = mdl.Course.Ix.init(course_ix),
                            .classes = course.classes,
                            .students = students,
                        });
                    },
                    SplitStrategy.PerGroup_MergeSmall => {
                        // Create single Lesson per Group
                        const lessons_start = single_lessons.items.len;
                        for (self.model.groups) |group| {
                            const intersection = course.classes.mask & group.classes.mask;
                            if (intersection != 0) {
                                const classes = mdl.ClassSet{ .mask = intersection };

                                var students: usize = 0;
                                var it = classes.iterator();
                                while (it.next()) |class_ix| {
                                    const class = class_ix.cptr(self.model.classes);
                                    students += class.count;
                                }

                                try single_lessons.append(mdl.Lesson{
                                    .course = mdl.Course.Ix.init(course_ix),
                                    .classes = classes,
                                    .students = students,
                                });
                            }
                        }

                        // Repeatable merge the two smallest Lessons
                        while (true) {
                            const my_lessons = single_lessons.items[lessons_start..];
                            if (my_lessons.len < 2)
                                break;

                            const Fn = struct {
                                pub fn call(_: void, a: mdl.Lesson, b: mdl.Lesson) bool {
                                    return a.students > b.students;
                                }
                            };
                            std.sort.block(mdl.Lesson, my_lessons, {}, Fn.call);
                            const small = &my_lessons[my_lessons.len - 1];
                            const large = &my_lessons[my_lessons.len - 2];
                            if (small.students + large.students > self.classroom_capacity)
                                break;

                            large.students += small.students;
                            large.classes.mask |= small.classes.mask;

                            try single_lessons.resize(single_lessons.items.len - 1);
                        }
                    },
                    SplitStrategy.Random => {
                        // Setup class_ixs as slice of Class.Ix
                        var buffer: [Max.classes]mdl.Class.Ix = undefined;
                        var class_ixs: []mdl.Class.Ix = &buffer;
                        class_ixs.len = 0;
                        var it = course.classes.iterator();
                        while (it.next()) |class_ix| {
                            class_ixs.len += 1;
                            class_ixs[class_ixs.len - 1] = class_ix;
                        }

                        // Shuffle class_ixs
                        const rng = self.prng.random();
                        rng.shuffle(mdl.Class.Ix, class_ixs);

                        var maybe_lesson: ?mdl.Lesson = null;
                        for (class_ixs) |class_ix| {
                            const class = class_ix.cptr(self.model.classes);

                            if (maybe_lesson) |*lesson| {
                                if (lesson.students + class.count <= self.classroom_capacity) {
                                    lesson.students += class.count;
                                    lesson.classes.add(class_ix.ix);
                                } else {
                                    try single_lessons.append(lesson.*);
                                    maybe_lesson = null;
                                }
                            }

                            if (maybe_lesson == null) {
                                maybe_lesson = mdl.Lesson{
                                    .course = mdl.Course.Ix.init(course_ix),
                                    .classes = mdl.ClassSet{ .mask = @as(u64, 1) << @intCast(class_ix.ix) },
                                    .students = class.count,
                                };
                            }
                        }
                        if (maybe_lesson) |lesson|
                            try single_lessons.append(lesson);
                    },
                }
            }

            // Setup Lesson.section
            {
                var course_ix: mdl.Course.Ix = undefined;
                var section: usize = undefined;
                for (single_lessons.items, 0..) |*lesson, ix| {
                    if (ix == 0 or !course_ix.eql(lesson.course))
                        section = 0;

                    lesson.section = section;

                    course_ix = lesson.course;
                    section += 1;
                }
            }

            if (single_lessons.items.len > Max.sections)
                return Error.TooManySections;

            for (single_lessons.items) |lesson| {
                if (lesson.students > self.classroom_capacity) {
                    return Error.TooManyStudents;
                }
            }
        }

        var lesson_count: usize = 0;
        for (single_lessons.items) |lesson|
            lesson_count += lesson.course.cptr(self.model.courses).hours;

        self.model.lessons = try self.a.alloc(mdl.Lesson, lesson_count);
        self.model.lessons.len = 0;
        for (single_lessons.items) |single_lesson| {
            const course = single_lesson.course.cptr(self.model.courses);
            for (0..course.hours) |hour| {
                var lesson = single_lesson;
                lesson.hour = hour;

                self.model.lessons.len += 1;
                self.model.lessons[self.model.lessons.len - 1] = lesson;
            }
        }
        std.debug.assert(lesson_count == self.model.lessons.len);
    }
};
