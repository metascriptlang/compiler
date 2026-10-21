import { parseJson } from "std/serialize/json/parser";
import { JsonKind, JsonValue } from "std/serialize/json/types";
import { getDynamicField, asString } from "std/serialize/json/accessors";

function readObject(value: JsonValue): string {
	when (narrowedReceiver) {
		if (value.kind != JsonKind.Object) return "";
	}
	return value.getDynamicField("name").asString();
}

function readString(value: JsonValue): string {
	when (narrowedReceiver) {
		if (value.kind != JsonKind.String) return "";
	}
	return value.asString();
}

const parsed = parseJson("{\"name\":\"ok\"}");
if (!parsed.ok) throw new Error(parsed.error);
console.log(readObject(parsed.value));
const text = parseJson("\"ok\"");
if (!text.ok) throw new Error(text.error);
console.log(readString(text.value));
