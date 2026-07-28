const std = @import("std");

const Obfuscator = @import("Pipeline/Obfuscator.zig");
const ProgressLog = @import("Pipeline/ProgressLog.zig");

pub fn main(Initialize: std.process.Init) !void {
    const IoInterface = Initialize.io;

    var StandardInput = std.Io.File.stdin();
    var LineBuffer: [8192]u8 = undefined;
    var ReaderState = StandardInput.reader(IoInterface, &LineBuffer);
    const StandardInputReader = &ReaderState.interface;

    while (true) {
        std.debug.print("### ", .{});
        const RawLine = (StandardInputReader.takeDelimiter('\n') catch break) orelse break;
        const Path = TrimPath(RawLine);
        if (Path.len == 0) continue;
        Obfuscator.ObfuscateJar(IoInterface, Path) catch |Err| {
            ProgressLog.Failure(Err);
            continue;
        };
    }
}

fn TrimPath(Line: []const u8) []const u8 {
    var Result = std.mem.trim(u8, Line, " \t\r\n");
    if (Result.len >= 2) {
        const First = Result[0];
        const Last = Result[Result.len - 1];
        if ((First == '"' and Last == '"') or (First == '\'' and Last == '\'')) {
            Result = std.mem.trim(u8, Result[1 .. Result.len - 1], " \t\r\n");
        }
    }
    return Result;
}
