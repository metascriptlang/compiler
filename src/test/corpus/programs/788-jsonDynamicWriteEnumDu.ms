// @xfail(raiser): runs but stdout misses its @stdout line (exit=0)
// Parity program — two JSON paths no other corpus program pins: the IMPLICIT
// dynamic write (`j.field = value` routed through setDynamicField, where 505
// only calls the method by name), and decoding an enum-discriminated union
// through jsonValueToStructE — both the two variants and the rejection of a
// member name the enum does not declare.
//
// @stdout: write ok 7 neo|du click 1 2|du key Esc|du bad field 'kind': unknown discriminator value 'Swipe'
// @exit: 0

import { jsonValueToStructE } from "std/serialize/json";

enum EvKind { Click, KeyPress }

type Event = match (kind: EvKind) {
	EvKind.Click => { x: number, y: number },
	EvKind.KeyPress => { code: string },
};

function decodeEvent(text: string): string {
	const pr = parseJson(text);
	if (!pr.ok) { return "parse failed"; }
	const errs: string[] = [];
	const e: Event = jsonValueToStructE(pr.value, null as Event | null, errs, "");
	if (errs.length != 0) { return errs[0]; }
	if (e.kind == EvKind.Click) { return `click ${e.x} ${e.y}`; }
	return `key ${e.code}`;
}

function main(): void {
	const obj = jsonObject([], []);
	obj.count = jsonInt(7 as int64);
	obj.name = jsonString("neo");
	const count: int32 = obj.count;
	const name: string = obj.name;

	console.log(`write ok ${count} ${name}|du ${decodeEvent(`{"kind":"Click","x":1,"y":2}`)}|du ${decodeEvent(`{"kind":"KeyPress","code":"Esc"}`)}|du bad ${decodeEvent(`{"kind":"Swipe"}`)}`);
}

main();
