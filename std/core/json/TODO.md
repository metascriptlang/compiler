# JSON2 TODO

## Status: In Progress

Files created:
- types.ms — JsonKind, JsonValueData (discriminated union), JsonValue = Ref<JsonValueData>
- builder.ms — constructors (jsonNull, jsonBool, jsonNumber, jsonString, jsonArray, jsonObject)
- stringify.ms — compact + pretty serializers with escaping
- parser.ms — recursive descent, Result-based, depth-limited, UTF-16 surrogate support

## Blocking Issue

Result<JsonValue, string> generates mismatched C type names:
- `msResult_JsonValueDatastar__msString` (from named type alias)
- `msResult_msUnion_pw6w31star__msString` (from anonymous structural hash)

The union type loses its `typeName` when flowing through Ref + Result generic instantiation.

Root cause: when `createResult(Ref<JsonValueData>, string)` is created, the ok type
is `Ref<Union(JsonValueData)>`. The `getTypeDesc` for the inner Union uses the structural
hash instead of the named type alias, creating two different C typedef names for the same type.

## Next Steps

1. Fix union type name propagation through Ref + generic instantiation
2. Run parser tests end-to-end via C binary
3. Create index.cms + index.ms prelude files
4. Wire into globalImports (swap json → json2)
5. Update examples/json.ms to use json2
6. Delete old std/core/json
