// @stdout: 1
import { JsonKind, JsonValue } from "std/serialize/json";
import { sleepAsync } from "std/core/promise";

function pickJsonArray(): JsonValue | null {
	return { kind: JsonKind.Array, items: [{ kind: JsonKind.Null }] };
}

async function countJsonItems(): Promise<int32> {
	const held = pickJsonArray();
	let n = 0;
	if (held != null && held.kind == JsonKind.Array) n = held.items.length;
	await sleepAsync(1);
	return n;
}

console.log(await countJsonItems());
