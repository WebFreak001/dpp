/**
   Translate aggregates
 */
module dpp.cursor.aggregate;

import dpp.from;


string[] translateStruct(in from!"clang".Cursor cursor,
                         ref from!"dpp.runtime.context".Context context)
    @safe
{
    import clang: Cursor;
    assert(cursor.kind == Cursor.Kind.StructDecl);
    return translateAggregate(context, cursor, "struct");
}

string[] translateClass(in from!"clang".Cursor cursor,
                        ref from!"dpp.runtime.context".Context context)
    @safe
{
    import clang: Cursor;
    assert(cursor.kind == Cursor.Kind.ClassDecl);
    return translateAggregate(context, cursor, "struct");
}

string[] translateUnion(in from!"clang".Cursor cursor,
                        ref from!"dpp.runtime.context".Context context)
    @safe
{
    import clang: Cursor;
    assert(cursor.kind == Cursor.Kind.UnionDecl);
    return translateAggregate(context, cursor, "union");
}

string[] translateEnum(in from!"clang".Cursor cursor,
                       ref from!"dpp.runtime.context".Context context)
    @safe
{
    import clang: Cursor;
    import std.typecons: nullable;

    assert(cursor.kind == Cursor.Kind.EnumDecl);

    // Translate it twice so that C semantics are the same (global names)
    // but also have a named version for optional type correctness and
    // reflection capabilities.
    // This means that `enum Foo { foo, bar }` in C will become:
    // `enum Foo { foo, bar }` _and_
    // `enum foo = Foo.foo; enum bar = Foo.bar;` in D.

    auto enumName = spellingOrNickname(cursor, context);

    string[] lines;
    foreach(member; cursor) {
        if(!member.isDefinition) continue;
        auto memName = member.spelling;
        lines ~= `enum ` ~ memName ~ ` = ` ~ enumName ~ `.` ~ memName ~ `;`;
    }

    return
        translateAggregate(context, cursor, "enum", nullable(enumName)) ~
        lines;
}

// not pure due to Cursor.opApply not being pure
string[] translateAggregate(
    ref from!"dpp.runtime.context".Context context,
    in from!"clang".Cursor cursor,
    in string keyword,
    in from!"std.typecons".Nullable!string spelling = from!"std.typecons".Nullable!string()
)
    @safe
{
    import dpp.cursor.translation: translate;
    import clang: Cursor;
    import std.algorithm: map, any;
    import std.array: array;
    import std.conv: text;

    // remember all aggregate declarations
    context.aggregateDeclarations[spellingOrNickname(cursor, context)] = true;

    const name = spelling.isNull ? spellingOrNickname(cursor, context) : spelling.get;
    const firstLine = keyword ~ ` ` ~ name;

    if(!cursor.isDefinition) return [firstLine ~ `;`];

    string[] lines;
    lines ~= firstLine;
    lines ~= `{`;

    if(cursor.children.any!(a => a.isBitField)) {
        // The align(4) is to mimic C. There, `struct Foo { int f1: 2; int f2: 3}`
        // would have sizeof 4, where as the corresponding bit fields in D would have
        // size 1. So we correct here. See issue #7.
        lines ~= [`    import std.bitmanip: bitfields;`, ``, `    align(4):`];
    }

    // if the last seen member was a bitfield
    bool lastMemberWasBitField = false;
    // the combined (summed) bitwidths of the bitfields members seen so far
    int totalBitWidth = 0;

    void finishBitFields() {
        lines ~= text(`        uint, "", `, padding(totalBitWidth));
        lines ~= `    ));`;
        totalBitWidth = 0;
    }

    foreach(member; cursor.children) {

        if(member.kind == Cursor.Kind.PackedAttr) {
            lines ~= "align(1):";
            continue;
        }

        if(member.isBitField && !lastMemberWasBitField)
            lines ~= `    mixin(bitfields!(`;

        if(!member.isBitField && lastMemberWasBitField) finishBitFields;

        if(!member.isDefinition) continue;
        lines ~= translate(member, context).map!(a => "    " ~ a).array;

        lastMemberWasBitField = member.isBitField;
        if(member.isBitField) totalBitWidth += member.bitWidth;
    }

    context.log("last member was? ", lastMemberWasBitField);
    if(lastMemberWasBitField) finishBitFields;

    lines ~= `}`;

    return lines;
}

private int padding(in int totalBitWidth) @safe @nogc pure nothrow {
    for(int powerOfTwo = 8; powerOfTwo < 64; powerOfTwo *= 2) {
        if(powerOfTwo > totalBitWidth) return powerOfTwo - totalBitWidth;
    }

    assert(0);
}


string[] translateField(in from!"clang".Cursor field,
                        ref from!"dpp.runtime.context".Context context)
    @safe
{

    import dpp.cursor.dlang: maybeRename;
    import dpp.type: translate;
    import clang: Cursor, Type;
    import std.conv: text;
    import std.typecons: No;
    import std.algorithm: map, filter;
    import std.array: replace, array;
    import std.range: chain, only;

    assert(field.kind == Cursor.Kind.FieldDecl, text("Field of wrong kind: ", field));

    // It's possible one of the fields is a pointer to a structure that isn't declared anywhere,
    // so we try and remember it here to fix it later
    if(field.type.kind == Type.Kind.Pointer && field.type.pointee.canonical.kind == Type.Kind.Record) {
        const type = field.type.pointee.canonical;
        const translatedType = translate(type, context);
        // const becomes a problem if we have to define a struct at the end of all translations.
        // See it.compile.projects.nv_alloc_ops
        enum constPrefix = "const(";
        const cleanedType = type.isConstQualified
            ? translatedType[constPrefix.length .. $-1] // unpack from const(T)
            : translatedType;
        context.rememberFieldStruct(cleanedType);
    }

    // function pointer fields can have return or parameter types that are struct pointers
    // to undeclared structs. We need to remember they exist so that we may later declare the struct.
    if(field.type.kind == Type.Kind.Pointer && field.type.pointee.canonical.kind == Type.Kind.FunctionProto) {
        const type = field.type.pointee.canonical;
        const structTypes = chain(only(type.returnType), type.paramTypes)
            .filter!(a => a.kind == Type.Kind.Pointer && a.pointee.canonical.kind == Type.Kind.Record)
            .map!(a => a.pointee.canonical)
            .array;

        foreach(structType; structTypes) {
            const translatedType = translate(structTypes[0], context);
            // const becomes a problem if we have to define a struct at the end of all translations.
            // See it.compile.projects.nv_alloc_ops
            enum constPrefix = "const(";
            const cleanedType = type.isConstQualified
                ? translatedType[constPrefix.length .. $-1] // unpack from const(T)
                : translatedType;

            if(cleanedType != "va_list")
                context.rememberFieldStruct(cleanedType);
        }
    }

    const type = translate(field.type, context, No.translatingFunction);
    return field.isBitField
        ? [text("    ", type, `, "`, maybeRename(field, context), `", `, field.bitWidth, `,`)]
        : [text(type, " ", maybeRename(field, context), ";")];
}


// if the cursor is an aggregate in C, i.e. struct, union or enum
package bool isAggregateC(in from!"clang".Cursor cursor) @safe @nogc pure nothrow {
    import clang: Cursor;
    return
        cursor.kind == Cursor.Kind.StructDecl ||
        cursor.kind == Cursor.Kind.UnionDecl ||
        cursor.kind == Cursor.Kind.EnumDecl;

}

// return the spelling if it exists, or our made-up nickname for it if not
package string spellingOrNickname(in from!"clang".Cursor cursor,
                                  ref from!"dpp.runtime.context".Context context)
    @safe
{

    import std.conv: text;

    static int index;

    // If not anonymous, just return the spelling
    if(cursor.spelling != "") return cursor.spelling;

    // otherwise find what nickname we gave it

    if(cursor.hash !in context.cursorNickNames) {
        auto nick = newAnonymousName;
        context.nickNames ~= nick;
        context.cursorNickNames[cursor.hash] = nick;
    }

    return context.cursorNickNames[cursor.hash];
}


private string newAnonymousName() @safe {
    import std.conv: text;
    import core.atomic: atomicOp;
    shared static int index;
    return text("_Anonymous_", index.atomicOp!"+="(1));
}
