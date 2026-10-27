import { JsonValue, JsonKind, getDynamicField, asString, parseJson, jsonArray } from "std/core/json";

// A string-valued field of a top-level JSON object; "" when the text is not JSON, the field is
// absent, or its value is not a string.
export function extractJsonField(json: string, field: string): string {
	const parsed = parseJson(json);
	if (!parsed.ok) return "";
	return parsed.value.getDynamicField(field).asString();
}

// The items of the array in `field`; empty when the field is absent or not an array.
export function arrayField(obj: JsonValue, field: string): JsonValue[] {
	const v = obj.getDynamicField(field);
	if (v.kind != JsonKind.Array) return [];
	return v.items;
}

// A JSON object as parallel key and value arrays; a value that is not a string reads as "".
export function depsOf(obj: JsonValue): { keys: string[], values: string[] } {
	const keys: string[] = [];
	const values: string[] = [];
	if (obj.kind != JsonKind.Object) return { keys, values };
	for (let i = 0; i < obj.keys.length; i++) {
		keys.push(obj.keys[i]);
		values.push(obj.values[i].asString());
	}
	return { keys, values };
}

// ===== Tests =====

test "extractJsonField basic" {
	const json = "{\"version\":\"1.2.3\",\"url\":\"https://example.com\"}";
	assert extractJsonField(json, "version") == "1.2.3";
	assert extractJsonField(json, "url") == "https://example.com";
	assert extractJsonField(json, "missing") == "";
}

test "extractJsonField nested ignored" {
	const json = "{\"outer\":{\"inner\":\"deep\"},\"top\":\"val\"}";
	assert extractJsonField(json, "top") == "val";
}

test "extractJsonField reads spaced pairs and escaped quotes, and a non-string as empty" {
	assert extractJsonField("{\"message\": \"x\"}", "message") == "x";
	assert extractJsonField("{\"m\":\"a\\\"b\"}", "m") == "a\"b";
	assert extractJsonField("{\"n\":5}", "n") == "";
	assert extractJsonField("not json", "n") == "";
}

test "extractJsonField empty string value" {
	const json = "{\"token\":\"\"}";
	assert extractJsonField(json, "token") == "";
}

test "arrayField reads an array, and anything else as empty" {
	const parsed = parseJson('{ "a": [1, 2], "o": { "k": 1 }, "s": "x" }');
	assert parsed.ok;
	if (parsed.ok) {
		assert arrayField(parsed.value, "a").length == 2;
		assert arrayField(parsed.value, "o").length == 0;
		assert arrayField(parsed.value, "s").length == 0;
		assert arrayField(parsed.value, "missing").length == 0;
	}
}

test "depsOf flattens an object and reads a non-string value as empty" {
	const parsed = parseJson('{ "a": "1.0.0", "b": 2, "c": null }');
	assert parsed.ok;
	if (parsed.ok) {
		const deps = depsOf(parsed.value);
		assert deps.keys.length == 3 && deps.keys[2] == "c";
		assert deps.values[0] == "1.0.0" && deps.values[1] == "" && deps.values[2] == "";
		assert depsOf(jsonArray([])).keys.length == 0;
	}
}
