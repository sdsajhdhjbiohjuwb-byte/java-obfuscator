const std = @import("std");
const ClassFileModel = @import("../Classfile/ClassFileModel.zig");
const BytecodeInstructionModel = @import("../Classfile/BytecodeInstructionModel.zig");

const ClassStrip = [_][]const u8{ "SourceFile", "SourceDebugExtension", "RuntimeVisibleTypeAnnotations", "RuntimeInvisibleTypeAnnotations", "Signature", "Deprecated", "Synthetic" };
const MethodStrip = [_][]const u8{ "MethodParameters", "RuntimeVisibleTypeAnnotations", "RuntimeInvisibleTypeAnnotations", "Signature", "Deprecated", "Synthetic" };
const FieldStrip = [_][]const u8{ "RuntimeVisibleTypeAnnotations", "RuntimeInvisibleTypeAnnotations", "Signature", "Deprecated", "Synthetic" };
const CodeStrip = [_][]const u8{ "LineNumberTable", "LocalVariableTable", "LocalVariableTypeTable", "RuntimeVisibleTypeAnnotations", "RuntimeInvisibleTypeAnnotations" };

fn IsNameInList(CandidateName: []const u8, NameList: []const []const u8) bool {
    for (NameList) |CurrentName| {
        if (std.mem.eql(u8, CandidateName, CurrentName)) return true;
    }
    return false;
}

fn FilterAttributesByNames(
    AllocatorHandle: std.mem.Allocator,
    Pool: *const ClassFileModel.ConstantPool,
    Attributes: *std.ArrayList(ClassFileModel.Attribute),
    Names: []const []const u8,
) !void {
    var KeptAttributes: std.ArrayList(ClassFileModel.Attribute) = .empty;
    for (Attributes.items) |CurrentAttribute| {
        if (!IsNameInList(Pool.Utf8Text(CurrentAttribute.NameIndex), Names)) try KeptAttributes.append(AllocatorHandle, CurrentAttribute);
    }
    Attributes.* = KeptAttributes;
}

pub fn DebugAttributeStripper(AllocatorHandle: std.mem.Allocator, ClassFileHandle: *ClassFileModel.ClassFile) !void {
    try FilterAttributesByNames(AllocatorHandle, &ClassFileHandle.ConstantPool, &ClassFileHandle.Attributes, &ClassStrip);
    for (ClassFileHandle.Fields.items) |*Field| {
        try FilterAttributesByNames(AllocatorHandle, &ClassFileHandle.ConstantPool, &Field.Attributes, &FieldStrip);
    }
    for (ClassFileHandle.Methods.items) |*Method| {
        try FilterAttributesByNames(AllocatorHandle, &ClassFileHandle.ConstantPool, &Method.Attributes, &MethodStrip);
        if (ClassFileModel.FindAttribute(Method.Attributes.items, &ClassFileHandle.ConstantPool, "Code")) |CodeAttributeIndex| {
            var Code = try BytecodeInstructionModel.ParseCode(AllocatorHandle, Method.Attributes.items[CodeAttributeIndex].Info);
            try FilterAttributesByNames(AllocatorHandle, &ClassFileHandle.ConstantPool, &Code.Attributes, &CodeStrip);
            Method.Attributes.items[CodeAttributeIndex].Info = try BytecodeInstructionModel.SerializeCode(AllocatorHandle, &Code);
        }
    }
}
