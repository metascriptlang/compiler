// nim-guard: a value built by a routine that formats a scalar is still fresh,
//   and a struct holding an actor handle beside plain data crosses to an actor.
//
// INVARIANT (isolation check, callee purity): `String(x)` of a number,
//   boolean, string or enum writes nothing, so a routine calling it keeps its
//   result a sole owner that moves into `spawn { move }` and into an actor
//   constructor. An actor handle is sendable, so the plain-data walk stops at
//   it and never reports the actor's private fields.
//
// WHAT IT CATCHES: `String` charged as an external call with unknown writes
//   (wings codec corruptRow, factServer), and an actor handle's fields read
//   as plain data of the struct that holds it (wings factTail).
//
// RED MEANS: one of the shapes below is refused, or carries the wrong text.
//
// GUARD-JS

enum Tone { Low, High }

interface Row { label: string; n: int32; }

function makeRow(n: int32): Row {
	return { label: String(n) + String(n > 1) + String(Tone.High) + String("!"), n: n };
}

actor Store {
	row: Row;
	constructor(row: Row) { this.row = row; }
	label(): string { return this.row.label; }
}

struct Query { name: string; call: () => int32; }

class HubCore {
	queries: Vec<Query> = [];
}

actor Hub {
	core: HubCore = new HubCore();
	bump(): int32 { this.core.queries.push({ name: "q", call: () => 1 }); return this.core.queries.length; }
}

struct Link { hub: Hub; n: int32; }

actor Tail {
	link: Link;
	constructor(link: Link) { this.link = link; }
	n(): int32 { return this.link.n; }
}

async function main(): Promise<int32> {
	const row = makeRow(2);
	const s = new Store(move row);
	const r = makeRow(3);
	const moved = await spawn(() => r.label, { move: [r] });
	const link: Link = { hub: new Hub(), n: 4 };
	const t = new Tail(move link);
	const fromActor = await s.label();
	if (fromActor != "2trueHigh!") { throw "GUARD RED: actor constructor got " + fromActor; }
	if (moved != "3trueHigh!") { throw "GUARD RED: spawn move got " + moved; }
	if (await t.n() != 4) { throw "GUARD RED: actor handle beside plain data"; }
	console.log("GUARD-OK");
	return 0;
}
await main();
