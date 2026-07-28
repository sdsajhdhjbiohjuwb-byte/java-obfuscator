const std = @import("std");

pub fn Qualified(AllocatorHandle: std.mem.Allocator, Owner: []const u8, Name: []const u8, Descriptor: []const u8) ![]u8 {
    return std.fmt.allocPrint(AllocatorHandle, "{s}\x00{s}\x00{s}", .{ Owner, Name, Descriptor });
}

pub fn Signature(AllocatorHandle: std.mem.Allocator, Name: []const u8, Descriptor: []const u8) ![]u8 {
    return std.fmt.allocPrint(AllocatorHandle, "{s}\x00{s}", .{ Name, Descriptor });
}
