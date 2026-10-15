// @stdout: if-one 1 m-one 1 sw-one 1|if-two q m-two q sw-two q|if-final true m-final true sw-other|1|one 3 two z
// note: a discriminated union finds its variant by the enum member the discriminant denotes, not by its spelling: member names with `_`, an enum named with `_`, an aliased and a namespace import, the match-type and the object-union declaration all narrow and construct the same variant.

import { My_Phase as P } from "./phase";
import * as ph from "./phase";

type Step = match (kind: P) {
	P.Round_One => { a: int32 },
	Round_Two => { b: string },
	P.Final => { c: boolean },
};

function viaIf(s: Step): string {
	if (s.kind == P.Round_One) return `if-one ${s.a}`;
	if (s.kind == ph.My_Phase.Round_Two) return `if-two ${s.b}`;
	return `if-final ${s.c}`;
}

function viaMatch(s: Step): string {
	match (s.kind) {
		P.Round_One => { return `m-one ${s.a}`; },
		P.Round_Two => { return `m-two ${s.b}`; },
		P.Final => { return `m-final ${s.c}`; },
	}
}

function viaSwitch(s: Step): string {
	switch (s.kind) {
		case P.Round_One: return `sw-one ${s.a}`;
		case P.Round_Two: return `sw-two ${s.b}`;
		default: return "sw-other";
	}
}

const xs: Step[] = [{ kind: P.Round_One, a: 1 }, { kind: ph.My_Phase.Round_Two, b: "q" }, { kind: P.Final, c: true }];
const lines: string[] = [];
for (const s of xs) lines.push(`${viaIf(s)} ${viaMatch(s)} ${viaSwitch(s)}`);

let total = 0;
let i = 0;
while (i < xs.length) {
	const s = xs[i];
	i += 1;
	if (s.kind != P.Round_One) continue;
	total += s.a;
}
lines.push(`${total}`);

type Pair =
	| { kind: P.Round_One, a: int32 }
	| { kind: P.Round_Two, b: string };

function show(s: Pair): string {
	if (s.kind == ph.My_Phase.Round_One) return `one ${s.a}`;
	return `two ${s.b}`;
}

lines.push(`${show({ kind: P.Round_One, a: 3 })} ${show({ kind: ph.My_Phase.Round_Two, b: "z" })}`);
console.log(lines.join("|"));
