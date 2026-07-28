const std = @import("std");
const Mapping = @import("../Rename/ClassNameMappingRegistry.zig").Mapping;

const ClassValuedKeys = [_][]const u8{ "Main-Class", "Premain-Class", "Agent-Class", "Launcher-Agent-Class", "Start-Class" };

pub fn ManifestRewriter(AllocatorHandle: std.mem.Allocator, ManifestBytes: []const u8, NameMapping: Mapping) ![]u8 {
    var LogicalLines: std.ArrayList([]const u8) = .empty;
    var CurrentLine: std.ArrayList(u8) = .empty;
    var HaveCurrentLine = false;

    var LineIterator = std.mem.splitScalar(u8, ManifestBytes, '\n');
    while (LineIterator.next()) |RawLine| {
        var Line = RawLine;
        if (Line.len > 0 and Line[Line.len - 1] == '\r') Line = Line[0 .. Line.len - 1];

        if (Line.len > 0 and Line[0] == ' ') {
            try CurrentLine.appendSlice(AllocatorHandle, Line[1..]);
        } else {
            if (HaveCurrentLine) {
                try LogicalLines.append(AllocatorHandle, try AllocatorHandle.dupe(u8, CurrentLine.items));
                CurrentLine.clearRetainingCapacity();
            }
            try CurrentLine.appendSlice(AllocatorHandle, Line);
            HaveCurrentLine = true;
        }
    }
    if (HaveCurrentLine) try LogicalLines.append(AllocatorHandle, try AllocatorHandle.dupe(u8, CurrentLine.items));

    var OutputBuffer = try std.Io.Writer.Allocating.initCapacity(AllocatorHandle, ManifestBytes.len + 64);
    const Writer = &OutputBuffer.writer;
    for (LogicalLines.items) |LogicalLine| {
        if (LogicalLine.len == 0) {
            try Writer.writeAll("\r\n");
            continue;
        }
        try FoldLine(Writer, try RewriteHeader(AllocatorHandle, LogicalLine, NameMapping));
    }
    try Writer.writeAll("\r\n");

    return OutputBuffer.written();
}

fn RewriteHeader(AllocatorHandle: std.mem.Allocator, Line: []const u8, NameMapping: Mapping) ![]const u8 {
    const ColonIndex = std.mem.indexOfScalar(u8, Line, ':') orelse return Line;
    const Key = Line[0..ColonIndex];
    var IsClassKey = false;
    for (ClassValuedKeys) |ClassKey| {
        if (std.ascii.eqlIgnoreCase(Key, ClassKey)) IsClassKey = true;
    }
    if (!IsClassKey) return Line;

    var ValueStartIndex = ColonIndex + 1;
    while (ValueStartIndex < Line.len and Line[ValueStartIndex] == ' ') ValueStartIndex += 1;
    const Value = std.mem.trimEnd(u8, Line[ValueStartIndex..], " ");
    const RemappedValue = (NameMapping.RemapDotted(AllocatorHandle, Value) catch null) orelse return Line;
    return try std.fmt.allocPrint(AllocatorHandle, "{s}: {s}", .{ Key, RemappedValue });
}

fn FoldLine(Writer: *std.Io.Writer, Line: []const u8) !void {
    if (Line.len <= 72) {
        try Writer.writeAll(Line);
        try Writer.writeAll("\r\n");
        return;
    }
    try Writer.writeAll(Line[0..72]);
    try Writer.writeAll("\r\n");
    var Index: usize = 72;
    while (Index < Line.len) {
        const EndIndex = @min(Index + 71, Line.len);
        try Writer.writeByte(' ');
        try Writer.writeAll(Line[Index..EndIndex]);
        try Writer.writeAll("\r\n");
        Index = EndIndex;
    }
}
