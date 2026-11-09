// @stdout: node 200 1
// @stdout: node 200 1
// @stdout: json 200 {"name":"q","v":["x"]}
// @stdout: json 200 {"name":"q","v":["x"]}
// note: an actor method binds an awaited struct and replies with `move` of its cyclic field; the binding is used in one state only, so it stays a local of that state and the move empties it, and the reply crosses as the only owner (no M1 at the caller's free).
import { JsonValue } from "std/serialize/json/types";
import { stringify } from "std/serialize/json/stringify";
import { jsonObject, jsonString, jsonArray } from "std/serialize/json/builder";
class Node { next: Node | null = null; n: int32 = 1; }
struct NodeAnswer { status: int32; body: Node; }
struct JsonAnswer { status: int32; body: JsonValue; }
async function buildNode(): Promise<NodeAnswer> { const a = new Node(); a.next = new Node(); a.next!.next = a; await Promise.resolve(0); return { status: 200, body: a }; }
async function buildJson(name: string): Promise<JsonAnswer> {
	await Promise.resolve(0);
	return { status: 200, body: jsonObject(["name", "v"], [jsonString(name), jsonArray([jsonString("x")])]) };
}
actor Reader {
	node(): NodeAnswer {
		let answered = await buildNode();
		return { status: answered.status, body: move answered.body };
	}
	json(name: string): JsonAnswer {
		let answered = await buildJson(name);
		return { status: answered.status, body: move answered.body };
	}
}
async function main(): Promise<void> {
	const r = new Reader();
	for (let i = 0; i < 2; i += 1) { const a = await r.node(); console.log(`node ${a.status} ${a.body.n}`); }
	for (let i = 0; i < 2; i += 1) { const a = await r.json("q"); console.log(`json ${a.status} ${stringify(a.body)}`); }
}
await main();
