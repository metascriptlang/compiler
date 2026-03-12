// MetaScript JSON — Public API
// For direct import: import { parseJson, stringify, ... } from "std/core/json";
// Prelude (no-import) path uses index.cms instead.

export { JsonKind, JsonValue } from "./types";
export { parseJson } from "./parser";
export { stringify } from "./stringify";
export {
	jsonNull, jsonBool, jsonNumber, jsonString, jsonArray, jsonObject, jsonObjectFromKV,
	get, isNull, set, push,
} from "./builder";

/**
 * An intrinsic object that provides functions to convert JavaScript values to and from the JavaScript Object Notation (JSON) format.
 */
export class JSON {
	/**
	 * Converts a JavaScript Object Notation (JSON) string into an object.
	 * @param input A valid JSON string.
	 * @throws {SyntaxError} If `input` is not valid JSON.
	 */
	static parse<T>(input: string): Result<T, string> { unreachable; };

	/**
	 * Converts a JavaScript value to a JavaScript Object Notation (JSON) string.
	 * @param value A JavaScript value, usually an object or array, to be converted.
	 */
	static stringify<T>(value: T): string { unreachable };
}

// ===== Typed JSON API =====
// Usage: const person = try jsonParse<Person>(input);
// Monomorphize resolves <T>, builtinLower generates per-type deserializer.

/**
 * Converts a JavaScript Object Notation (JSON) string into an object.
 * @param input A valid JSON string.
 * @throws {SyntaxError} If `input` is not valid JSON.
 */
@builtin("JsonParse")
export extern function jsonParse<T>(input: string): Result<T, string>;

/**
 * Converts a JavaScript value to a JavaScript Object Notation (JSON) string.
 * @param value A JavaScript value, usually an object or array, to be converted.
 */
@builtin("JsonStringify")
export extern function jsonStringify<T>(value: T): string;
