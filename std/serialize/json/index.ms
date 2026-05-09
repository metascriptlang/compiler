// JSON codec — explicit-import hub.
//
// Exports both the macro codec (jsonStringify, jsonValueToStruct) and the
// SERIALIZE capability instances (jsonUntyped). Re-exports the public
// macros so `import { jsonStringify } from "std/serialize/json"` brings
// `jsonValueOf` along (recursive expansion calls it by name in the emitted
// AST — must be in the importer's symbol table).

export { jsonStringify, jsonValueOf } from "./encode";
export { jsonValueToStruct } from "./decode";
export { parseJson } from "./parser";
export { JsonValue, JsonKind } from "./types";

import { parseJson } from "./parser";
import { JsonValue } from "./types";
import { UntypedTree } from "../contracts";

// SERIALIZE UntypedTree<V> capability instance for JSON.
// Cross-format tools that target `UntypedTree<V>` accept this for JSON input.
// Schema-bound formats (Protobuf, Avro) deliberately don't export an instance.
export const jsonUntyped: UntypedTree<JsonValue> = {
	parseValue: parseJson,
};
