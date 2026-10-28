// @stdout: trim=a plain=ab map=7,3,- cursor=0,1,2 chain=ABC
// note: a macro-time helper calls a method of a class: an extension call on a field, a plain method, a Map field read and written in methods, a cursor that changes across calls, a method that calls another method of its class.

import { Node, NodeKind } from "std/meta";

class Reader {
	text: string;
	pos: int32 = 0;
	scalars: Map<string, int32> = new Map();
	constructor(t: string) { this.text = t; }
	trimmed(): string { return this.text.trim(); }
	joined(extra: string): string { return this.text + extra; }
	put(k: string, v: int32): void { this.scalars.set(k, v); }
	get(k: string): string { return this.scalars.has(k) ? String(this.scalars.get(k)!) : "-"; }
	next(): int32 { const p = this.pos; this.pos = p + 1; return p; }
	upper(): string { return this.trimmed().toUpperCase(); }
}

macro table(): Node {
	const r = new Reader("  a  ");
	const q = new Reader("a");
	const m = new Reader("");
	m.put("x", 7);
	m.put("y", 3);
	const c = new Reader("");
	const s = "trim=" + r.trimmed() + " plain=" + q.joined("b")
		+ " map=" + m.get("x") + "," + m.get("y") + "," + m.get("z")
		+ " cursor=" + String(c.next()) + "," + String(c.next()) + "," + String(c.next())
		+ " chain=" + new Reader(" abc ").upper();
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: s };
}

console.log(table());
