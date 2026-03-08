// MetaScript JSON — Public API
// For direct import: import { parseJson, stringify, ... } from "std/core/json";
// Prelude (no-import) path uses index.cms instead.

export { JsonKind, JsonValue } from "./types";
export { parseJson } from "./parser";
export { stringify } from "./stringify";
export {
	jsonNull, jsonBool, jsonNumber, jsonString, jsonArray, jsonObject, jsonObjectFromKV,
	get, at, asString, asNumber, asBool, isNull, len, set, push,
} from "./builder";

// ===== Typed JSON API =====
// Usage: const person = try jsonParse<Person>(input);
// Monomorphize resolves <T>, builtinLower generates per-type deserializer.

@builtin("JsonParse")
export extern function jsonParse<T>(input: string): Result<T, string>;

@builtin("JsonStringify")
export extern function jsonStringify<T>(value: T): string;
