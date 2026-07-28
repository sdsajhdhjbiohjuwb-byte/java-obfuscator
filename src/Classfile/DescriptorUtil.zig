fn RawTypeLength(Descriptor: []const u8, Index: usize) usize {
    return switch (Descriptor[Index]) {
        '[' => Block: {
            var Cursor = Index;
            while (Cursor < Descriptor.len and Descriptor[Cursor] == '[') : (Cursor += 1) {}
            if (Cursor >= Descriptor.len) break :Block Descriptor.len - Index;
            break :Block (Cursor - Index) + RawTypeLength(Descriptor, Cursor);
        },
        'L' => Block: {
            var Cursor = Index + 1;
            while (Cursor < Descriptor.len and Descriptor[Cursor] != ';') : (Cursor += 1) {}
            break :Block (Cursor - Index) + 1;
        },
        else => 1,
    };
}

pub fn ParameterCount(Descriptor: []const u8) usize {
    var Count: usize = 0;
    var Index: usize = 1;
    while (Index < Descriptor.len and Descriptor[Index] != ')') {
        Index += RawTypeLength(Descriptor, Index);
        Count += 1;
    }
    return Count;
}

const SupportFloatingPoint: bool = true;
const SupportReferences: bool = true;

fn SupportedTypeLength(Descriptor: []const u8, Index: usize) ?usize {
    return switch (Descriptor[Index]) {
        'I', 'J', 'Z', 'B', 'C', 'S' => 1,
        'F', 'D' => if (SupportFloatingPoint) 1 else null,
        'L' => Block: {
            if (!SupportReferences) break :Block null;
            var Cursor = Index + 1;
            while (Cursor < Descriptor.len and Descriptor[Cursor] != ';') : (Cursor += 1) {}
            if (Cursor >= Descriptor.len) break :Block null;
            break :Block Cursor - Index + 1;
        },
        '[' => Block: {
            if (!SupportReferences) break :Block null;
            var Cursor = Index;
            while (Cursor < Descriptor.len and Descriptor[Cursor] == '[') : (Cursor += 1) {}
            if (Cursor >= Descriptor.len) break :Block null;
            const ElementLength = SupportedTypeLength(Descriptor, Cursor) orelse break :Block null;
            break :Block Cursor - Index + ElementLength;
        },
        else => null,
    };
}

pub fn DescriptorIsSupported(Descriptor: []const u8) bool {
    if (Descriptor.len < 3 or Descriptor[0] != '(') return false;
    var Index: usize = 1;
    while (Index < Descriptor.len and Descriptor[Index] != ')') {
        const Consumed = SupportedTypeLength(Descriptor, Index) orelse return false;
        Index += Consumed;
    }
    if (Index >= Descriptor.len) return false;
    Index += 1;
    if (Index < Descriptor.len and Descriptor[Index] == 'V') return Index + 1 == Descriptor.len;
    const ReturnLength = SupportedTypeLength(Descriptor, Index) orelse return false;
    return Index + ReturnLength == Descriptor.len;
}
