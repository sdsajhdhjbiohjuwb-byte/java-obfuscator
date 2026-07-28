const std = @import("std");
const IdentifierGenerator = @import("../Passes/IdentifierGenerator.zig");

pub const Pair = struct {
    OldInternal: []const u8,
    NewInternal: []const u8,
    OldDotted: []const u8,
    NewDotted: []const u8,
};

pub const Mapping = struct {
    Pairs: []Pair,
    InternalToNew: std.StringHashMap([]const u8),

    pub fn RemapInternal(Self: Mapping, OldName: []const u8) ?[]const u8 {
        return Self.InternalToNew.get(OldName);
    }

    pub fn RemapDotted(Self: Mapping, AllocatorHandle: std.mem.Allocator, OldDottedName: []const u8) !?[]const u8 {
        const InternalName = try DotToSlash(AllocatorHandle, OldDottedName);
        const NewInternalName = Self.InternalToNew.get(InternalName) orelse return null;
        return try SlashToDot(AllocatorHandle, NewInternalName);
    }
};

pub fn DotToSlash(AllocatorHandle: std.mem.Allocator, SourceString: []const u8) ![]u8 {
    const Result = try AllocatorHandle.dupe(u8, SourceString);
    for (Result) |*Char| {
        if (Char.* == '.') Char.* = '/';
    }
    return Result;
}

pub fn SlashToDot(AllocatorHandle: std.mem.Allocator, SourceString: []const u8) ![]u8 {
    const Result = try AllocatorHandle.dupe(u8, SourceString);
    for (Result) |*Char| {
        if (Char.* == '/') Char.* = '.';
    }
    return Result;
}

fn LessThanString(_: void, Left: []const u8, Right: []const u8) bool {
    return std.mem.lessThan(u8, Left, Right);
}

fn LengthDescending(_: void, Left: Pair, Right: Pair) bool {
    return Left.OldInternal.len > Right.OldInternal.len;
}

pub fn Build(AllocatorHandle: std.mem.Allocator, Names: []const []const u8, ClassPackage: []const u8) !Mapping {
    const SortedNames = try AllocatorHandle.dupe([]const u8, Names);
    std.mem.sort([]const u8, SortedNames, {}, LessThanString);

    const Pairs = try AllocatorHandle.alloc(Pair, SortedNames.len);
    var InternalToNewMap = std.StringHashMap([]const u8).init(AllocatorHandle);

    for (SortedNames, 0..) |OldName, Index| {
        const SimpleName = try IdentifierGenerator.AbcName(AllocatorHandle, Index);
        const NewInternalName = if (ClassPackage.len == 0)
            SimpleName
        else
            try std.fmt.allocPrint(AllocatorHandle, "{s}/{s}", .{ ClassPackage, SimpleName });
        Pairs[Index] = try MakePair(AllocatorHandle, OldName, NewInternalName);
        try InternalToNewMap.put(OldName, NewInternalName);
    }

    std.mem.sort(Pair, Pairs, {}, LengthDescending);

    return .{
        .Pairs = Pairs,
        .InternalToNew = InternalToNewMap,
    };
}

fn MakePair(AllocatorHandle: std.mem.Allocator, OldInternalName: []const u8, NewInternalName: []const u8) !Pair {
    return .{
        .OldInternal = OldInternalName,
        .NewInternal = NewInternalName,
        .OldDotted = try SlashToDot(AllocatorHandle, OldInternalName),
        .NewDotted = try SlashToDot(AllocatorHandle, NewInternalName),
    };
}
