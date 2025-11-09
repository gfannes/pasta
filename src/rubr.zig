// Output from `rake export[idx,cli,Env]` from https://github.com/gfannes/rubr from 2025-11-09

const std = @import("std");

// Export from 'src/idx.zig'
pub const idx = struct {
    pub const Range = struct {
        const Self = @This();
    
        begin: usize = 0,
        end: usize = 0,
    
        pub fn empty(self: Self) bool {
            return self.begin == self.end;
        }
        pub fn size(self: Self) usize {
            return self.end - self.begin;
        }
    };
    
    // Type-safe index to work with 'pointers into a slice'
    pub fn Ix(T: type) type {
        return struct {
            const Self = @This();
    
            ix: usize = 0,
    
            pub fn init(ix: usize) Self {
                return Self{ .ix = ix };
            }
    
            pub fn eql(self: Self, rhs: Self) bool {
                return self.ix == rhs.ix;
            }
    
            pub fn get(self: Self, slice: []T) ?*T {
                if (self.ix >= slice.len)
                    return null;
                return &slice[self.ix];
            }
            pub fn cget(self: Self, slice: []const T) ?*const T {
                if (self.ix >= slice.len)
                    return null;
                return &slice[self.ix];
            }
    
            // Unchecked version of get()
            pub fn ptr(self: Self, slice: []T) *T {
                return &slice[self.ix];
            }
            pub fn cptr(self: Self, slice: []const T) *const T {
                return &slice[self.ix];
            }
    
            pub fn format(self: Self, io: *std.Io.Writer) !void {
                try io.print("{}", .{self.ix});
            }
        };
    }
    
};

// Export from 'src/cli.zig'
pub const cli = struct {
    // Allocates everything on env.aa: no need for deinit() or lifetime management
    pub const Args = struct {
        const Self = @This();
    
        env: Env,
        argv: [][]const u8 = &.{},
    
        pub fn setupFromOS(self: *Self) !void {
            const a = self.env.aa;
    
            const os_argv = try std.process.argsAlloc(a);
            defer std.process.argsFree(a, os_argv);
    
            self.argv = try a.alloc([]const u8, os_argv.len);
    
            for (os_argv, 0..) |str, ix| {
                self.argv[ix] = try a.dupe(u8, str);
            }
        }
        pub fn setupFromData(self: *Self, argv: []const []const u8) !void {
            const a = self.env.aa;
    
            self.argv = try a.alloc([]const u8, argv.len);
            for (argv, 0..) |slice, ix| {
                self.argv[ix] = try a.dupe(u8, slice);
            }
        }
    
        pub fn pop(self: *Self) ?Arg {
            if (self.argv.len == 0) return null;
    
            const a = self.env.aa;
            const arg = a.dupe(u8, std.mem.sliceTo(self.argv[0], 0)) catch return null;
            self.argv.ptr += 1;
            self.argv.len -= 1;
    
            return Arg{ .arg = arg };
        }
    };
    
    pub const Arg = struct {
        const Self = @This();
    
        arg: []const u8,
    
        pub fn is(self: Arg, sh: []const u8, lh: []const u8) bool {
            return std.mem.eql(u8, self.arg, sh) or std.mem.eql(u8, self.arg, lh);
        }
    
        pub fn as(self: Self, T: type) !T {
            return try std.fmt.parseInt(T, self.arg, 10);
        }
    };
    
};

// Export from 'src/Env.zig'
pub const Env = struct {
    const Env_ = @This();
    
    // General purpose allocator
    a: std.mem.Allocator = undefined,
    // Arena allocator
    aa: std.mem.Allocator = undefined,
    
    io: std.Io = undefined,
    
    log: *const Log = undefined,
    
    pub const Instance = struct {
        const Self = @This();
        const GPA = std.heap.GeneralPurposeAllocator(.{});
        const AA = std.heap.ArenaAllocator;
    
        log: Log = undefined,
        gpa: GPA = undefined,
        aa: AA = undefined,
        io: std.Io.Threaded = undefined,
        maybe_start: ?std.time.Instant = null,
    
        pub fn init(self: *Self) void {
            self.log = Log{};
            self.log.init();
            self.gpa = GPA{};
            self.aa = AA.init(self.gpa.allocator());
            self.io = std.Io.Threaded.init(self.gpa.allocator());
            self.maybe_start = std.time.Instant.now() catch null;
        }
        pub fn deinit(self: *Self) void {
            self.io.deinit();
            self.aa.deinit();
            if (self.gpa.deinit() == .leak) {
                self.log.err("Found memory leaks in Env\n", .{}) catch {};
            }
            self.log.deinit();
        }
    
        pub fn env(self: *Self) Env_ {
            return .{ .a = self.gpa.allocator(), .aa = self.aa.allocator(), .io = self.io.io(), .log = &self.log };
        }
    
        pub fn duration_ns(self: Self) u64 {
            const start = self.maybe_start orelse return 0;
            const now = std.time.Instant.now() catch return 0;
            return now.since(start);
        }
    };
    
    pub fn duration_ns(env: Env_) u64 {
        const inst: *const Instance = @fieldParentPtr("log", env.log);
        return inst.duration_ns();
    }
};

// Export from 'src/Log.zig'
pub const Log = struct {
    pub const Error = error{FilePathTooLong};
    
    // &improv: Support both buffered and non-buffered logging
    const Self = @This();
    
    const Autoclean = struct {
        buffer: [std.fs.max_path_bytes]u8 = undefined,
        filepath: []const u8 = &.{},
    };
    
    _do_close: bool = false,
    _file: std.fs.File = std.fs.File.stdout(),
    
    _buffer: [1024]u8 = undefined,
    _writer: std.fs.File.Writer = undefined,
    
    _io: *std.Io.Writer = undefined,
    
    _lvl: usize = 0,
    
    _autoclean: ?Autoclean = null,
    
    pub fn init(self: *Self) void {
        self.initWriter();
    }
    pub fn deinit(self: *Self) void {
        std.debug.print("Log.deinit()\n", .{});
        self.closeWriter() catch {};
        if (self._autoclean) |autoclean| {
            std.debug.print("Removing '{s}'\n", .{autoclean.filepath});
            std.fs.deleteFileAbsolute(autoclean.filepath) catch {};
        }
    }
    
    // Any '%' in 'filepath' will be replaced with the process id
    const Options = struct {
        autoclean: bool = false,
    };
    pub fn toFile(self: *Self, filepath: []const u8, options: Options) !void {
        try self.closeWriter();
    
        var pct_count: usize = 0;
        for (filepath) |ch| {
            if (ch == '%')
                pct_count += 1;
        }
    
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const filepath_clean = if (pct_count > 0) blk: {
            var pid_buf: [32]u8 = undefined;
            const pid_str = try std.fmt.bufPrint(&pid_buf, "{}", .{std.c.getpid()});
            if (filepath.len + pct_count * pid_str.len >= buf.len)
                return Error.FilePathTooLong;
            var ix: usize = 0;
            for (filepath) |ch| {
                if (ch == '%') {
                    for (pid_str) |c| {
                        buf[ix] = c;
                        ix += 1;
                    }
                } else {
                    buf[ix] = ch;
                    ix += 1;
                }
            }
            break :blk buf[0..ix];
        } else blk: {
            break :blk filepath;
        };
    
        if (std.fs.path.isAbsolute(filepath_clean)) {
            self._file = try std.fs.createFileAbsolute(filepath_clean, .{});
            if (options.autoclean) {
                self._autoclean = undefined;
                const fp = self._autoclean.?.buffer[0..filepath_clean.len];
                std.mem.copyForwards(u8, fp, filepath_clean);
                if (self._autoclean) |*autoclean| {
                    autoclean.filepath = fp;
                    std.debug.print("Setup autoclean for '{s}'\n", .{autoclean.filepath});
                }
            }
        } else {
            self._file = try std.fs.cwd().createFile(filepath_clean, .{});
        }
        self._do_close = true;
    
        self.initWriter();
    }
    
    pub fn setLevel(self: *Self, lvl: usize) void {
        self._lvl = lvl;
    }
    
    pub fn writer(self: Self) *std.Io.Writer {
        return self._io;
    }
    
    pub fn print(self: Self, comptime fmt: []const u8, args: anytype) !void {
        try self._io.print(fmt, args);
        try self._io.flush();
    }
    pub fn info(self: Self, comptime fmt: []const u8, args: anytype) !void {
        try self.print("Info: " ++ fmt, args);
    }
    pub fn warning(self: Self, comptime fmt: []const u8, args: anytype) !void {
        try self.print("Warning: " ++ fmt, args);
    }
    pub fn err(self: Self, comptime fmt: []const u8, args: anytype) !void {
        try self.print("Error: " ++ fmt, args);
    }
    
    pub fn level(self: Self, lvl: usize) ?*std.Io.Writer {
        if (self._lvl >= lvl)
            return self._io;
        return null;
    }
    
    fn initWriter(self: *Self) void {
        self._writer = self._file.writer(&self._buffer);
        self._io = &self._writer.interface;
    }
    fn closeWriter(self: *Self) !void {
        try self._io.flush();
        if (self._do_close) {
            self._file.close();
            self._do_close = false;
        }
    }
    
};
