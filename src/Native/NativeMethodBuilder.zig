const std = @import("std");

const RegistrationEntry = struct {
    Owner: []const u8,
    Name: []const u8,
    Signature: []const u8,
    FunctionName: []const u8,
};

const IntegrityItem = struct {
    Path: []const u8,
    Hash: i64,
};

pub const Builder = struct {
    Lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    Allocator: std.mem.Allocator,
    Functions: std.ArrayList([]const u8) = .empty,
    Registrations: std.ArrayList(RegistrationEntry) = .empty,
    IntegrityEntries: std.ArrayList(IntegrityItem) = .empty,

    pub fn Initialize(Allocator: std.mem.Allocator) Builder {
        return .{ .Allocator = Allocator };
    }

    fn Acquire(Self: *Builder) void {
        while (Self.Lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn Release(Self: *Builder) void {
        Self.Lock.store(false, .release);
    }

    pub fn Add(Self: *Builder, Function: []const u8, Owner: []const u8, Name: []const u8, Signature: []const u8, FunctionName: []const u8) !void {
        Self.Acquire();
        defer Self.Release();
        try Self.Functions.append(Self.Allocator, try Self.Allocator.dupe(u8, Function));
        try Self.Registrations.append(Self.Allocator, .{
            .Owner = try Self.Allocator.dupe(u8, Owner),
            .Name = try Self.Allocator.dupe(u8, Name),
            .Signature = try Self.Allocator.dupe(u8, Signature),
            .FunctionName = try Self.Allocator.dupe(u8, FunctionName),
        });
    }

    pub fn AddIntegrity(Self: *Builder, Path: []const u8, Hash: i64) !void {
        Self.Acquire();
        defer Self.Release();
        try Self.IntegrityEntries.append(Self.Allocator, .{ .Path = try Self.Allocator.dupe(u8, Path), .Hash = Hash });
    }

    pub fn ZigSource(Self: *Builder, OutputAllocator: std.mem.Allocator) ![]u8 {
        var Out: std.ArrayList(u8) = .empty;
        try Out.appendSlice(OutputAllocator, "const std = @import(\"std\");\npub const panic = std.debug.FullPanic(struct { pub fn Halt(_: []const u8, _: ?usize) noreturn { @trap(); } }.Halt);\nconst JniNativeCore = @import(\"JniNativeCore.zig\");\ncomptime { _ = JniNativeCore; }\n");
        try Out.appendSlice(OutputAllocator, "pub const IntegrityManifest = [_]JniNativeCore.IntegrityEntry{");
        for (Self.IntegrityEntries.items) |Item| {
            try Out.appendSlice(OutputAllocator, try std.fmt.allocPrint(OutputAllocator, " .{{ .Path = \"{s}\", .Hash = {d} }},", .{ Item.Path, Item.Hash }));
        }
        try Out.appendSlice(OutputAllocator, " };\n");
        for (Self.Functions.items) |Function| {
            try Out.appendSlice(OutputAllocator, Function);
            try Out.append(OutputAllocator, '\n');
        }
        try Out.appendSlice(OutputAllocator, "pub fn RegisterTranspiled(Environment: ?*anyopaque) void {\n");
        if (Self.Registrations.items.len == 0) {
            try Out.appendSlice(OutputAllocator, "    _ = Environment;\n");
        }
        for (Self.Registrations.items, 0..) |Owned, OwnerIndex| {
            var Seen = false;
            for (Self.Registrations.items[0..OwnerIndex]) |Prior| {
                if (std.mem.eql(u8, Prior.Owner, Owned.Owner)) {
                    Seen = true;
                    break;
                }
            }
            if (Seen) continue;
            try Out.appendSlice(OutputAllocator, "    {\n        const Methods = [_]JniNativeCore.JavaNativeInterfaceNativeMethod{\n");
            for (Self.Registrations.items) |Entry| {
                if (!std.mem.eql(u8, Entry.Owner, Owned.Owner)) continue;
                try Out.appendSlice(OutputAllocator, try std.fmt.allocPrint(OutputAllocator, "            .{{ .Name = \"{s}\", .Signature = \"{s}\", .FunctionPointer = @ptrFromInt(@intFromPtr(&{s})) }},\n", .{ Entry.Name, Entry.Signature, Entry.FunctionName }));
            }
            try Out.appendSlice(OutputAllocator, try std.fmt.allocPrint(OutputAllocator, "        }};\n        JniNativeCore.RegisterForClass(Environment, \"{s}\", &Methods);\n    }}\n", .{Owned.Owner}));
        }
        try Out.appendSlice(OutputAllocator, "}\n");
        return Out.toOwnedSlice(OutputAllocator);
    }
};
