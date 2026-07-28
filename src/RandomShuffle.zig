const std = @import("std");

pub fn Shuffle(comptime ElementType: type, Items: []ElementType, RandomSource: std.Random) void {
    var Index: usize = Items.len;
    while (Index > 1) {
        Index -= 1;
        const InnerIndex = RandomSource.uintLessThan(usize, Index + 1);
        const Temporary = Items[Index];
        Items[Index] = Items[InnerIndex];
        Items[InnerIndex] = Temporary;
    }
}
