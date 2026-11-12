// A tagged struct's variant payload reads back through JSON.parse<T> by the same
// per-field reader a plain struct uses: a struct, a nullable struct, a nullable
// scalar and a plain scalar round-trip, and a wrong payload is refused naming its field.
//
// @stdout: round {"kind":"Move","to":{"x":1,"y":2}}
// @stdout: round {"kind":"Pane","pane":{"x":3,"y":4},"n":7,"tag":"a"}
// @stdout: round {"kind":"Pane","pane":null,"n":null,"tag":"b"}
// @stdout: round {"kind":"Stop"}
// @stdout: field 'to': expected object, got int; field 'to.x': expected int, got null; field 'to.y': expected int, got null
// @stdout: field 'pane': expected object, got string; field 'pane.x': expected int, got null; field 'pane.y': expected int, got null
// @stdout: lenient Move 1 2
// @stdout: lenient Pane null 7
// @exit: 0

import { jsonValueToStruct } from "std/serialize/json";

struct Point {
	x: int32;
	y: int32;
}

enum Kind {
	Move,
	Pane,
	Stop,
}

struct Cmd = match (kind: Kind) {
	Kind.Move => { to: Point },
	Kind.Pane => { pane: Point | null, n: int32 | null, tag: string },
	Kind.Stop => {},
};

function roundTrip(c: Cmd): void {
	const text = JSON.stringify(c);
	const back = JSON.parse<Cmd>(text);
	console.log(back.ok && JSON.stringify(back.value) == text ? "round " + text : "broken " + (back.ok ? JSON.stringify(back.value) : back.error));
}

roundTrip({ kind: Kind.Move, to: { x: 1, y: 2 } });
roundTrip({ kind: Kind.Pane, pane: { x: 3, y: 4 }, n: 7, tag: "a" });
roundTrip({ kind: Kind.Pane, pane: null, n: null, tag: "b" });
roundTrip({ kind: Kind.Stop });
const wrongStruct = JSON.parse<Cmd>('{"kind":"Move","to":3}');
console.log(wrongStruct.ok ? "accepted" : wrongStruct.error);
const wrongNullable = JSON.parse<Cmd>('{"kind":"Pane","pane":"p","n":1,"tag":"c"}');
console.log(wrongNullable.ok ? "accepted" : wrongNullable.error);
const lenientMove = JSON.parseValue('{"kind":"Move","to":{"x":1,"y":2}}');
const lenientPane = JSON.parseValue('{"kind":"Pane","pane":null,"n":7,"tag":"d"}');
if (lenientMove.ok && lenientPane.ok) {
	const m: Cmd = jsonValueToStruct(lenientMove.value, null as Cmd | null);
	const p: Cmd = jsonValueToStruct(lenientPane.value, null as Cmd | null);
	console.log(m.kind == Kind.Move ? `lenient Move ${m.to.x} ${m.to.y}` : "broken");
	console.log(p.kind == Kind.Pane ? `lenient Pane ${p.pane == null ? "null" : "set"} ${p.n}` : "broken");
}
