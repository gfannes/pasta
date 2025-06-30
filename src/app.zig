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
    RegenCountTooLow,
    IterationsTooLow,
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
    const Solutions = std.ArrayList(Solution);

    a: std.mem.Allocator,
    log: *const rubr.log.Log,
    hours_per_week: usize = 0,
    max_students: usize = 0,
    min_students: usize = 0,
    iterations: usize = 0,
    regen_count: usize = 0,
    max_steps: usize = 0,
    output_dir: ?[]const u8 = null,
    lesson_table: csv.Table,
    count: mdl.Count = .{},
    model: mdl.Model,
    prng: std.Random.DefaultPrng,
    solutions: Solutions,

    pub fn init(a: std.mem.Allocator, log: *const rubr.log.Log) Self {
        return Self{
            .a = a,
            .log = log,
            .hours_per_week = 32,
            .max_students = 26,
            .min_students = 20,
            .lesson_table = csv.Table.init(a),
            .model = mdl.Model.init(a),
            .prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp())),
            .solutions = Solutions.init(a),
        };
    }
    pub fn deinit(self: *Self) void {
        self.lesson_table.deinit();
        self.model.deinit();
        for (self.solutions.items) |*solution|
            solution.deinit();
        self.solutions.deinit();
    }

    pub fn setup(self: *Self, config: cfg.Config) !void {
        self.regen_count = config.regen_count;
        self.iterations = config.iterations;
        self.max_steps = config.max_steps;
        self.output_dir = config.output_dir;

        const input_fp = config.input_fp orelse {
            try self.log.err("Please specify an input file\n", .{});
            return Error.ExpectedInputFilepath;
        };
        try self.loadLessonTable(input_fp);

        self.count = try deriveCounts(self.lesson_table, self.log);
        try self.model.alloc(self.count);
        try self.loadData();
    }

    pub fn learn(self: *Self) !void {
        const Cb = struct {
            const My = @This();

            app: *Self,
            regen: usize,
            a: std.mem.Allocator,
            log: *const rubr.log.Log,
            iterations: usize,
            best_unfit: *usize,
            mutex: *std.Thread.Mutex,

            pub fn init(my: *My, app: *Self, regen: usize, iterations: usize, best_unfit: *usize, mutex: *std.Thread.Mutex) void {
                my.app = app;
                my.regen = regen;
                my.a = app.a;
                my.log = app.log;
                my.iterations = iterations;
                my.best_unfit = best_unfit;
                my.mutex = mutex;
            }
            pub fn deinit(my: *My) void {
                _ = my;
            }
            pub fn call(my: *My) void {
                my.call_() catch {};
            }
            fn call_(my: *My) !void {
                var maybe_best_solution: ?Solution = null;

                for (0..my.iterations) |iteration| {
                    if (my.log.level(2)) |w|
                        try w.print("Regen {}, iteration {}\n", .{ my.regen, iteration });

                    const lessons: []mdl.Lesson = try my.app.createLessons(SplitStrategy.Random);
                    defer my.a.free(lessons);

                    // If we make it this far, let's dig a bit deeper
                    const max_step_factor: usize = if (iteration <= 500) 1 else 10;

                    var maybe_solution = my.app.fit(lessons, max_step_factor) catch null;
                    if (maybe_solution) |*solution| {
                        if (maybe_best_solution) |*best_solution| {
                            defer solution.deinit();
                            if (solution.unfit <= best_solution.unfit) {
                                std.mem.swap(Solution, solution, best_solution);

                                if (my.log.level(1)) |w|
                                    try w.print("Found better solution in regen {} iteration {}: unfit {}\n", .{ my.regen, iteration, best_solution.unfit });

                                my.mutex.lock();
                                defer my.mutex.unlock();
                                if (best_solution.unfit <= my.best_unfit.*) {
                                    my.best_unfit.* = best_solution.unfit;
                                    try my.log.print("\nFound better solution in regen {} iteration {}: unfit {}\n", .{ my.regen, iteration, my.best_unfit.* });
                                    try best_solution.schedule.write(my.log.writer(), my.app.model, .{});
                                }
                            }
                        } else {
                            maybe_best_solution = solution.*;
                        }
                    }

                    var best_solution = &(maybe_best_solution orelse unreachable);
                    var low_performer: bool = false;
                    if (iteration >= 100 and best_solution.unfit > 20)
                        low_performer = true;
                    if (iteration >= 500 and best_solution.unfit > 5)
                        low_performer = true;
                    if (low_performer) {
                        if (my.log.level(1)) |w|
                            try w.print("Regen {} is a low performer: unfit {} at iteration {}\n", .{ my.regen, best_solution.unfit, iteration });
                        best_solution.deinit();
                        maybe_best_solution = null;
                        break;
                    }
                }

                if (maybe_best_solution) |best_solution| {
                    my.mutex.lock();
                    defer my.mutex.unlock();
                    try my.app.solutions.append(best_solution);
                    maybe_best_solution = null;
                }

                const a = my.a;
                my.deinit();
                a.destroy(my);
            }
        };

        if (self.regen_count <= 0)
            return Error.RegenCountTooLow;
        if (self.iterations <= 0)
            return Error.IterationsTooLow;
        var best_unfit: usize = std.math.maxInt(usize);
        std.debug.print("Regen count: {},  iterations per regen {}\n", .{ self.regen_count, self.iterations });
        var mutex = std.Thread.Mutex{};

        var thread_pool: std.Thread.Pool = undefined;
        try thread_pool.init(.{ .allocator = self.a, .n_jobs = 32 });
        defer thread_pool.deinit();
        for (0..self.regen_count) |regen| {
            // Cb.call will deinit/destroy itself
            const cb = try self.a.create(Cb);
            cb.init(self, regen, self.iterations, &best_unfit, &mutex);
            try thread_pool.spawn(Cb.call, .{cb});
        }
    }

    pub fn writeOutput(self: *Self) !void {
        const Fn = struct {
            pub fn ascending(_: void, x: Solution, y: Solution) bool {
                return x.unfit < y.unfit;
            }
            pub fn descending(_: void, x: Solution, y: Solution) bool {
                return y.unfit < x.unfit;
            }
        };

        if (self.output_dir) |output_dir| {
            std.sort.block(Solution, self.solutions.items, {}, Fn.ascending);
            try std.fs.cwd().makePath(output_dir);
        } else {
            std.sort.block(Solution, self.solutions.items, {}, Fn.descending);
        }

        for (self.solutions.items, 0..) |solution, ix| {
            if (ix >= 10)
                // Enough output
                break;

            var output_log = rubr.log.Log{};
            output_log.init();
            defer output_log.deinit();

            var write_config: mdl.Schedule.WriteConfig = .{};
            if (self.output_dir) |output_dir| {
                const fp = try std.fmt.allocPrint(self.a, "{s}/solution-{:02}.csv", .{ output_dir, ix });
                defer self.a.free(fp);

                try output_log.toFile(fp);
                write_config.mode = mdl.Schedule.WriteMode.Csv;
            }

            try output_log.print("Unfit,{}\n", .{solution.unfit});
            try solution.schedule.write(output_log.writer(), self.model, write_config);
        }
    }

    pub fn fit(self: *Self, all_lessons: []mdl.Lesson, max_step_factor: usize) !?Solution {
        var schedule = mdl.Schedule.init(self.a);
        defer schedule.deinit();
        try schedule.alloc(self.hours_per_week, self.count.classes);

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

        const max_steps = self.max_steps * max_step_factor;
        var fit_data = FitData{ .max_steps = max_steps };
        defer fit_data.deinit();

        if (self.fit_(lessons_to_fit, &schedule, &fit_data)) |ok| {
            if (ok) {
                try self.log.info("Found solution!\n", .{});
            } else {
                // try self.log.info("Could not find solution\n", .{});
            }
        } else |err| {
            switch (err) {
                Error.Stop => {
                    // try self.log.info("Stopping search\n", .{});
                },
                else => {
                    try self.log.err("Something went wrong during search: {}\n", .{err});
                    return err;
                },
            }
        }

        if (fit_data.maybe_solution) |solution| {
            defer fit_data.maybe_solution = null;
            return solution;
        }

        return null;
    }

    const FitData = struct {
        max_steps: usize,
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
    fn fit_(self: Self, lessons: []mdl.Lesson, schedule: *mdl.Schedule, fit_data: *FitData) !bool {
        if (try fit_data.store(lessons.len, schedule.*)) {
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
                try schedule.write(w, self.model, .{});
            }
        }

        if (lessons.len == 0)
            // No more lessons to fit: we are done and found a fitting solution
            return true;

        if (fit_data.step >= fit_data.max_steps)
            return Error.Stop;
        fit_data.step += 1;

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
                            try schedule.write(w, self.model, .{});
                        }
                        std.mem.swap(mdl.Lesson, lesson, &lessons[0]);

                        if (try self.fit_(lessons[1..], schedule, fit_data))
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
                try schedule.write(w, self.model, .{});
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
                    try schedule.write(w, self.model, .{});
                }

                if (try self.fit_(lessons[1..], schedule, fit_data))
                    return true;

                if (self.log.level(1)) |w|
                    try w.print("\tRemoving {s}-{}-{}\n", .{ course.name, lesson.section, lesson.hour });
                schedule.updateLesson(hour, lesson, false);
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
    fn createLessons(self: *Self, split_strategy: SplitStrategy) ![]mdl.Lesson {
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

                switch (split_strategy) {
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
                            if (small.students + large.students > self.max_students)
                                break;

                            large.students += small.students;
                            large.classes.mask |= small.classes.mask;

                            try single_lessons.resize(single_lessons.items.len - 1);

                            if (large.students >= self.min_students)
                                break;
                        }
                    },
                    SplitStrategy.Random => {
                        // Setup class_ixs as slice of Class.Ix and compute total student count for this Course
                        var buffer: [Max.classes]mdl.Class.Ix = undefined;
                        var class_ixs: []mdl.Class.Ix = &buffer;
                        var students: usize = 0;
                        class_ixs.len = 0;
                        var it = course.classes.iterator();
                        while (it.next()) |class_ix| {
                            class_ixs.len += 1;
                            class_ixs[class_ixs.len - 1] = class_ix;

                            const class = class_ix.cptr(self.model.classes);
                            students += class.count;
                        }

                        if (students <= self.max_students) {
                            // All students fit in a single Lesson: do not shuffle and split
                            // Especially because the check against min_students might result in more than 1 Lesson
                            try single_lessons.append(mdl.Lesson{
                                .course = mdl.Course.Ix.init(course_ix),
                                .classes = course.classes,
                                .students = students,
                            });
                        } else {
                            // Shuffle class_ixs
                            const rng = self.prng.random();
                            rng.shuffle(mdl.Class.Ix, class_ixs);

                            // Add Classes to Lessons until their size is in [min_students, max_students]
                            var maybe_lesson: ?mdl.Lesson = null;
                            for (class_ixs) |class_ix| {
                                const class = class_ix.cptr(self.model.classes);

                                if (maybe_lesson) |*lesson| {
                                    if (lesson.students + class.count <= self.max_students) {
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

                                if (maybe_lesson) |lesson| {
                                    if (lesson.students >= self.min_students) {
                                        // This Lesson is full enough. If we try to fill it to max_students, small Classes end-up blocking the search.
                                        try single_lessons.append(lesson);
                                        maybe_lesson = null;
                                    }
                                }
                            }
                            if (maybe_lesson) |lesson|
                                try single_lessons.append(lesson);
                        }
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
                if (lesson.students > self.max_students) {
                    return Error.TooManyStudents;
                }
            }
        }

        var lesson_count: usize = 0;
        for (single_lessons.items) |lesson|
            lesson_count += lesson.course.cptr(self.model.courses).hours;

        var lessons = try self.a.alloc(mdl.Lesson, lesson_count);
        lessons.len = 0;
        for (single_lessons.items) |single_lesson| {
            const course = single_lesson.course.cptr(self.model.courses);
            for (0..course.hours) |hour| {
                var lesson = single_lesson;
                lesson.hour = hour;

                lessons.len += 1;
                lessons[lessons.len - 1] = lesson;
            }
        }
        std.debug.assert(lesson_count == lessons.len);

        return lessons;
    }
};
