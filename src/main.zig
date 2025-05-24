const std = @import("std");
const cfg = @import("cfg.zig");
const csv = @import("csv.zig");
const model = @import("model.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const a = gpa.allocator();

    var config = cfg.Config.init(a);
    defer config.deinit();
    config.lesson_fp = "/home/geertf/pier/test.csv";

    var lesson_table = csv.Table.init(a);
    try lesson_table.loadFromFile(config.lesson_fp);
    defer lesson_table.deinit();

    var count = model.Model.Count{ .hours = 32 };
    for (lesson_table.rows[0][2..]) |cell| {
        if (std.mem.eql(u8, cell.str, "class"))
            count.classes += 1;
    }
    for (lesson_table.rows[2..]) |row| {
        if (std.mem.eql(u8, row[0].str, "group"))
            count.groups += 1;
        if (std.mem.eql(u8, row[0].str, "course"))
            count.courses += 1;
    }

    std.debug.print("count: {}\n", .{count});

    var m = model.Model.init(a);
    defer m.deinit();
    try m.alloc(count);

    var class_ix: usize = 0;
    for (lesson_table.rows[0], 0..) |cell, ix| {
        if (std.mem.eql(u8, cell.str, "class")) {
            defer class_ix += 1;
            m.classes[class_ix].name = lesson_table.rows[1][ix].str;
        }
    }

    var group_ix: usize = 0;
    var course_ix: usize = 0;
    for (lesson_table.rows[2..]) |row| {
        if (std.mem.eql(u8, row[0].str, "group")) {
            defer group_ix += 1;
            m.groups[group_ix].name = row[1].str;
        }
        if (std.mem.eql(u8, row[0].str, "course")) {
            defer course_ix += 1;
            m.courses[course_ix].name = row[1].str;
        }
    }
}
