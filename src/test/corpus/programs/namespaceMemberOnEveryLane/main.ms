// Parity program — a routine, a class, a constant, an enum member and a routine value reached through
// `import * as t` resolve to the module's symbol on every lane, the Raiser included.
//
// @stdout: T 42 5 7 1 10 | 6 8 local

import * as t from "./tags";

function tag(): string { return "local"; }

function viaParam(twice: int32): int32 {
	return t.twice(twice);
}

const b = new t.Box(5);
const f = t.twice;
console.log(`${t.tag()} ${t.twice(21)} ${b.get()} ${t.K} ${t.Color.Green as int32} ${t.apply(t.twice, 5)} | ${viaParam(3)} ${f(4)} ${tag()}`);
