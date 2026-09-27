// bug390 — `move arr[i]` copied the element silently and left the array intact
//
// Symptom:    `const x = move arr[0]; arr[0] == null` printed false: the move compiled as a plain
//             copy (incref), so neither the source was zeroed nor the move refused.
//
// Root cause: the element walk copies through passCopyToSink under the move, and reportFailedMove
//             answered only for identifiers. Nim raises errFailedMove for every copy made while
//             inEnsureMove > 0 (injectdestructors.nim passCopyToSink/genCopy), and an element of a
//             T[] sits behind the array's shared cell, which Nim never moves out of
//             (`ensureMove arr[][0]` on a `ref seq` is refused even at its last read).
//
// Fix:        reportFailedMove reports every expression passCopyToSink copies while inEnsureMove > 0,
//             naming the location as Nim does.

import { compileToC } from "../helpers";

const readAfter = `
interface Leaf { v: string; }
export function run(): string {
	const arr: Leaf[] = [{ v: "a" }, { v: "b" }];
	const x = move arr[0];
	return x.v + (arr[0] == null ? "null" : "kept");
}
`;

const nestedReturn = `
export function run(): string {
	const grid: string[][] = [["a" + String(1), "b"], ["c"]];
	return move grid[0][1];
}
`;

const sinkArgument = `
interface Leaf { v: string; }
export function run(): string {
	const arr: Leaf[] = [{ v: "a" }, { v: "b" }];
	const out: Leaf[] = [];
	out.push(move arr[1]);
	return out[0].v;
}
`;

const fieldMove = `
class H { f: string = ""; }
export function run(): string {
	const h = new H();
	h.f = "x" + String(1);
	const t = move h.f;
	return t + h.f;
}
`;

test "bug390: moving an element read afterwards is rejected at the move" {
	const c = compileToC(readAfter);
	assert !c.ok, "expected an error, compiled clean";
	assert c.error.indexOf("cannot move 'arr[0]', which introduces an implicit copy") >= 0, "wrong message: " + c.error;
}

test "bug390: moving a nested element out of a return is rejected" {
	const c = compileToC(nestedReturn);
	assert !c.ok, "expected an error, compiled clean";
	assert c.error.indexOf("cannot move 'grid[0][1]'") >= 0, "wrong message: " + c.error;
}

test "bug390: moving an element into a sink argument is rejected" {
	const c = compileToC(sinkArgument);
	assert !c.ok, "expected an error, compiled clean";
	assert c.error.indexOf("cannot move 'arr[1]'") >= 0, "wrong message: " + c.error;
}

test "bug390: moving a field still compiles" {
	const c = compileToC(fieldMove);
	assert c.ok, "field move rejected: " + (c.ok ? "" : c.error);
}
