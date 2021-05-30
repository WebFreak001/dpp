/**
   Enum translation
 */
module dpp.translation.enum_;

import dpp.from;
import dpp.translation.docs;

string[] translateEnumConstant(in from!"clang".Cursor cursor,
                               ref from!"dpp.runtime.context".Context context)
    @safe
{
    import dpp.translation.dlang: maybeRename;
    import clang: Cursor;
    import std.conv: text;

    assert(cursor.kind == Cursor.Kind.EnumConstantDecl);
    context.log("    Enum Constant Value: ", cursor.enumConstantValue);
    context.log("    tokens: ", cursor.tokens);

    return [get_comment(cursor, false), maybeRename(cursor, context) ~ ` = ` ~ text(cursor.enumConstantValue) ~ `, `];
}
