const std = @import("std");
const rubr = @import("rubr.zig");

pub const Error = error{
    CouldNotReadAllData,
    ExpectedDelimiter,
    CouldNotFindClosingQuote,
};

pub const Table = struct {
    const Self = @This();
    const Dim = struct {
        rows: usize = 0,
        cols: usize = 0,
    };
    const Row = []Cell;

    env: rubr.Env,
    content: []const u8 = &.{},
    newline: []const u8 = &.{},
    dim: Dim = .{},
    rows: []Row = &.{},

    pub fn init(env: rubr.Env) Self {
        return Self{ .env = env };
    }
    pub fn deinit(self: *Self) void {
        self.env.a.free(self.content);
        for (self.rows) |row|
            self.env.a.free(row);
        self.env.a.free(self.rows);
    }

    pub fn loadFromFile(self: *Self, fp: []const u8) !void {
        try self.readContent(fp);
        self.deriveNewline();
        try self.deriveDim();
        try self.allocateCells();
        try self.parseData();
    }

    fn readContent(self: *Self, fp: []const u8) !void {
        var file = try std.Io.Dir.cwd().openFile(self.env.io, fp, .{ .mode = .read_only });
        defer file.close(self.env.io);

        const stat = try file.stat(self.env.io);
        const buf = try self.env.a.alloc(u8, stat.size);
        errdefer self.env.a.free(buf);

        if (try file.readPositionalAll(self.env.io, buf, 0) != stat.size)
            return Error.CouldNotReadAllData;

        self.content = buf;
    }

    fn deriveNewline(self: *Self) void {
        self.newline = if (std.mem.indexOf(u8, self.content, "\r\n") != null) "\r\n" else "\n";
    }

    fn deriveDim(self: *Self) !void {
        self.newline = if (std.mem.indexOf(u8, self.content, "\r\n") != null) "\r\n" else "\n";

        self.dim = .{};

        var strange = rubr.strng.Strange{ .content = self.content };
        while (strange.popLine()) |line| {
            if (line.len == 0)
                continue;

            self.dim.rows += 1;

            var cols: usize = 0;
            var line_strng = rubr.strng.Strange{ .content = line };
            while (!line_strng.empty()) {
                cols += 1;
                if (line_strng.popChar('"')) {
                    _ = line_strng.popTo('"');
                    if (!line_strng.empty() and !line_strng.popChar(','))
                        return error.ExpectedDelimiter;
                } else {
                    if (line_strng.popTo(',') == null) {
                        _ = line_strng.popAll();
                    }
                }
            }

            self.dim.cols = @max(self.dim.cols, cols);
        }
    }

    fn allocateCells(self: *Self) !void {
        self.rows = try self.env.a.alloc(Row, self.dim.rows);
        for (self.rows) |*row| {
            row.* = try self.env.a.alloc(Cell, self.dim.cols);
            @memset(row.*, .{});
        }
    }

    fn parseData(self: *Self) !void {
        var rix: usize = 0;
        var strange = rubr.strng.Strange{ .content = self.content };
        while (strange.popLine()) |line| {
            if (line.len == 0)
                continue;
            defer rix += 1;

            var cix: usize = 0;
            var line_strng = rubr.strng.Strange{ .content = line };
            while (!line_strng.empty()) {
                defer cix += 1;

                var cell_str: []const u8 = &.{};
                if (line_strng.popChar('"')) {
                    cell_str = line_strng.popTo('"') orelse return error.CouldNotFindClosingQuote;
                    if (!line_strng.empty() and !line_strng.popChar(','))
                        return error.ExpectedDelimiter;
                } else {
                    if (line_strng.popTo(',')) |str| {
                        cell_str = str;
                    } else if (line_strng.popAll()) |str| {
                        cell_str = str;
                    }
                }

                const cell = Cell{ .str = cell_str, .int = std.fmt.parseInt(i64, cell_str, 10) catch null };
                self.rows[rix][cix] = cell;
            }
        }
    }
};

pub const Cell = struct {
    str: []const u8 = &.{},
    int: ?i64 = null,
};
