const std = @import("std");

pub const index = struct {
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
        };
    }
};

pub const cli = struct {
    pub const Args = struct {
        const Self = @This();

        argv: [][]const u8 = &.{},
        aa: std.heap.ArenaAllocator,

        pub fn init(a: std.mem.Allocator) Self {
            return Self{ .aa = std.heap.ArenaAllocator.init(a) };
        }
        pub fn deinit(self: *Self) void {
            self.aa.deinit();
        }

        pub fn setupFromOS(self: *Self) !void {
            const aaa = self.aa.allocator();

            self.argv = try aaa.alloc([]const u8, std.os.argv.len);
            for (std.os.argv, 0..) |c_str, ix| {
                const len = std.mem.len(c_str);
                self.argv[ix] = try aaa.dupe(u8, c_str[0..len]);
            }
        }
        pub fn setupFromData(self: *Self, argv: []const []const u8) !void {
            const aaa = self.aa.allocator();

            self.argv = try aaa.alloc([]const u8, argv.len);
            for (argv, 0..) |slice, ix| {
                self.argv[ix] = try aaa.dupe(u8, slice);
            }
        }

        pub fn pop(self: *Self) ?Arg {
            if (self.argv.len == 0) return null;

            const aaa = self.aa.allocator();
            const arg = aaa.dupe(u8, std.mem.sliceTo(self.argv[0], 0)) catch return null;
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

pub const log = struct {
    pub const Log = struct {
        const Self = @This();
        const BufferedWriter = std.io.BufferedWriter(4096, std.fs.File.Writer);
        pub const Writer = std.fs.File.Writer;

        _file: std.fs.File = std.io.getStdOut(),
        _do_close: bool = false,
        _buffered_writer: BufferedWriter = undefined,
        _writer: Writer = undefined,
        _lvl: usize = 0,

        pub fn init(self: *Self) void {
            self.initWriter();
        }
        pub fn deinit(self: *Self) void {
            self.closeWriter() catch {};
        }

        pub fn toFile(self: *Self, filepath: []const u8) !void {
            try self.closeWriter();

            if (std.fs.path.isAbsolute(filepath))
                self._file = try std.fs.createFileAbsolute(filepath, .{})
            else
                self._file = try std.fs.cwd().createFile(filepath, .{});
            self._do_close = true;

            self.initWriter();
        }

        pub fn setLevel(self: *Self, lvl: usize) void {
            self._lvl = lvl;
        }

        pub fn writer(self: Self) Writer {
            return self._writer;
        }

        pub fn print(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self._writer.print(fmt, args);
        }
        pub fn info(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self._writer.print("Info: " ++ fmt, args);
        }
        pub fn warning(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self._writer.print("Warning: " ++ fmt, args);
        }
        pub fn err(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self._writer.print("Error: " ++ fmt, args);
        }

        pub fn level(self: Self, lvl: usize) ?Writer {
            if (self._lvl >= lvl)
                return self._writer;
            return null;
        }

        fn initWriter(self: *Self) void {
            self._writer = self._file.writer();
            // self.buffered_writer = std.io.bufferedWriter(self.file.writer());
            // self.writer = self.buffered_writer.writer();
        }
        fn closeWriter(self: *Self) !void {
            // try self.buffered_writer.flush();
            if (self._do_close) {
                self._file.close();
                self._do_close = false;
            }
        }
    };
};
