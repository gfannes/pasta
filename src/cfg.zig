const std = @import("std");
const rubr = @import("rubr.zig");
const Env = rubr.Env;

pub const Error = error{
    CouldNotFindExecutable,
    ExpectedFilepath,
    ExpectedFolder,
    ExpectedNumber,
    UnsupportedArgument,
};

const Default = struct {
    const regen_count: usize = 100;
    const iterations: usize = 1000;
    const max_steps: usize = 10000;
    const min_students: usize = 20;
    const max_students: usize = 26;
};

pub const Config = struct {
    const Self = @This();

    args: rubr.cli.Args,

    exe_name: ?[]const u8 = null,

    print_help: bool = false,

    verbose: usize = 0,
    input_fp: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    regen_count: usize = Default.regen_count,
    iterations: usize = Default.iterations,
    max_steps: usize = Default.max_steps,

    min_students: usize = Default.min_students,
    max_students: usize = Default.max_students,

    pub fn init(env: Env) Self {
        return Self{ .args = rubr.cli.Args{ .env = env } };
    }
    pub fn deinit(_: *Self) void {}

    pub fn parse(self: *Self) !void {
        try self.args.setupFromOS();

        self.exe_name = (self.args.pop() orelse return Error.CouldNotFindExecutable).arg;

        while (self.args.pop()) |arg| {
            if (arg.is("-h", "--help")) {
                self.print_help = true;
            } else if (arg.is("-v", "--verbose")) {
                self.verbose = try (self.args.pop() orelse return Error.ExpectedNumber).as(usize);
            } else if (arg.is("-i", "--input")) {
                self.input_fp = (self.args.pop() orelse return Error.ExpectedFilepath).arg;
            } else if (arg.is("-o", "--output")) {
                self.output_dir = (self.args.pop() orelse return Error.ExpectedFolder).arg;
            } else if (arg.is("-r", "--regen")) {
                self.regen_count = try (self.args.pop() orelse return Error.ExpectedNumber).as(usize);
            } else if (arg.is("-n", "--iterations")) {
                self.iterations = try (self.args.pop() orelse return Error.ExpectedNumber).as(usize);
            } else if (arg.is("-m", "--max-step")) {
                self.max_steps = try (self.args.pop() orelse return Error.ExpectedNumber).as(usize);
            } else if (arg.is("-s", "--min-students")) {
                self.min_students = try (self.args.pop() orelse return Error.ExpectedNumber).as(usize);
            } else if (arg.is("-S", "--max-students")) {
                self.max_students = try (self.args.pop() orelse return Error.ExpectedNumber).as(usize);
            } else {
                return Error.UnsupportedArgument;
            }
        }
    }

    pub fn print(self: Self, w: *std.Io.Writer) !void {
        try w.print("Help for {s}\n", .{self.exe_name orelse "<unknown>"});
        try w.print("    -h/--help               Print this help\n", .{});
        try w.print("    -v/--verbose LEVEL      Verbosity level [optional, default is 0]\n", .{});
        try w.print("    -i/--input FILE         Input .csv file\n", .{});
        try w.print("    -o/--output FOLDER      Output folder\n", .{});
        try w.print("    -r/--regen COUNT        Number of sets of lessons to generate and test [optional, default is {}]\n", .{Default.regen_count});
        try w.print("    -n/--iterations COUNT   Number of iterations to process for each generated set of lessons [optional, default is {}]\n", .{Default.iterations});
        try w.print("    -m/--max-step COUNT     Maximum number of steps to take per iteration [optional, default is {}]\n", .{Default.max_steps});
        try w.print("    -s/--min-students COUNT Minimal number of students before a new Lesson is created [optional, default is {}]\n", .{Default.min_students});
        try w.print("    -S/--max-students COUNT Maximal number of students before a new Lesson is created [optional, default is {}]\n", .{Default.max_students});
        const description =
            \\After reading the input configuration, Courses are split into Lessons, given to random groups of Classes are created with size between 20 and 26 students.
            \\The number of different random splits that are tested is controlled by the '--regen' parameter. Note that each different random split can be processed on a different CPU.
            \\Once a set of Lessons is derived for each Course, only the Lessons that are not given to a complete ClassGroup will be fitted into the schedule.
            \\Before trying to fit those Lessons into the Schedule, they are randomized.
            \\The number of randomized reorders that are tested within a given set of Lessons is controlled by the '--iterations' parameter.
            \\For a given set and order of Lessons, backtracking is used to try and fill a Schedule:
            \\- When each Hour in the Schedule for a ClassGroup is either fully filled-in or empty, the first unprocessed Lesson is placed in the first available Hour that fits the Lesson.
            \\- When there is a Gap for a certain ClassGroup in the Schedule, a Lesson is searched that fits this Gap either in full or partial.
            \\
            \\To quickly find a good solution, preferrably with 0 unfit Lessons, it is:
            \\- Important to test enough different random splits of Courses into Lessons. Since such a random split can be processed in parallel, the '--regen' parameter should be set to at least the number of available CPUs in the system.
            \\- Important to stop testing random splits that lead to poor solutions. For this, if a given random split does not find a reasonable good solution within the first 500 iterations, it is not processed further.
            \\- If a random split survives the first 500 iterations, the '--max-step' is multiplied by 10 to give the backtracking algorithm more steps to find a solution.
            \\
            \\The input file must be a regular comma-separated value file. The first 3 columns and rows indicate the type, name and count of the respective cells.
            \\A row can have types:
            \\- 'group': defines a ClassGroup with a given name, indicating ClassGroup membership with a '1'
            \\- 'course': defines a Course with a given name and number of hours/week, indicating Classes that follow a Course with a '1'
            \\A column can have types:
            \\- 'class': defines a Class with a given name
            \\- 'constraint': not implemented yet
        ;
        try w.print("\n{s}\n\nDeveloped by Geert Fannes\n", .{description});
    }
};
