// @stdout: put=7 fill=a1,b2 count=3 words=2 passed=9 chain=16
// note: a std class instance crosses between a macro body and its helpers: a Map parameter, a Map a helper returns, a helper that hands its Map to another helper, a Set parameter and a Map of arrays.

import { Node, NodeKind } from "std/meta";

function put(m: Map<string, int32>, k: string): int32 {
	m.set(k, 7);
	return m.get(k) ?? -1;
}

function fill(m: Map<string, int32>): string {
	m.set("a", 1);
	m.set("b", 2);
	let out = "";
	for (const [k, v] of m) out = out + (out == "" ? "" : ",") + k + String(v);
	return out;
}

function fresh(): Map<string, int32> {
	const m = new Map<string, int32>();
	m.set("p", 1);
	m.set("q", 2);
	m.set("r", 3);
	return m;
}

function words(s: Set<string>, w: string): int32 {
	s.add(w);
	s.add(w);
	return s.size as int32;
}

function inner(m: Map<string, int32>): int32 {
	m.set("z", 9);
	return m.get("z") ?? -1;
}

function outer(m: Map<string, int32>): int32 {
	return inner(m) + 5;
}

function groups(m: Map<string, string[]>): int32 {
	m.set("g", ["x", "y"]);
	return m.get("g")!.length;
}

macro report(): Node {
	const m = new Map<string, int32>();
	const f = new Map<string, int32>();
	const s = new Set<string>();
	const g = new Map<string, string[]>();
	const text = "put=" + String(put(m, "k"))
		+ " fill=" + fill(f)
		+ " count=" + String(fresh().size)
		+ " words=" + String(words(s, "w") + words(s, "v") - 1)
		+ " passed=" + String(inner(new Map<string, int32>()))
		+ " chain=" + String(outer(new Map<string, int32>()) + groups(g));
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: text };
}

console.log(report());
