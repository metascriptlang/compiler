// @xfail(raiser): struct == compares by reference on raiser (card 2026-09-29-raiser-struct-equality-by-reference)
// @stdout: nested=true,false deep=true,false generic=true,false sameName=true,false,true,false local=true,false,false
// note: `==` on a struct compares a field whose type is declared in a module this file never imports, one and two levels down and inside a generic instance. Two modules that each declare a struct `Key`, and a local struct named like the nested foreign one, each compare through their own equality. Same output on every backend.

import { Outer } from "./lib/outer";
import { Top } from "./lib/top";
import { Holder } from "./lib/holder";
import { sameKeyA } from "./lib/keyA";
import { sameKeyB } from "./lib/keyB";

struct Inner { tag: string; }

function main(): void {
	const x: Outer = { id: 1, inner: { a: 0, b: 1 } };
	const y: Outer = { ...x };
	const z: Outer = { id: 1, inner: { a: 0, b: 2 } };
	const t: Top = { id: 1, m: { a: 2, d: { k: 3, s: "de" + "ep" } } };
	const u: Top = { id: 1, m: { a: 2, d: { k: 3, s: "deep" } } };
	const v: Top = { id: 1, m: { a: 2, d: { k: 3, s: "deed" } } };
	const h: Holder = { b: { v: { a: 1, b: 2 }, n: 3 } };
	const i: Holder = { ...h };
	const j: Holder = { b: { v: { a: 1, b: 9 }, n: 3 } };
	const p: Inner = { tag: "t" };
	const q: Inner = { tag: "t" };
	const r: Inner = { tag: "u" };
	console.log(`nested=${x == y},${x == z} deep=${t == u},${t == v} generic=${h == i},${h == j}`
		+ ` sameName=${sameKeyA(4, 4)},${sameKeyA(4, 5)},${sameKeyB(7, 7)},${sameKeyB(7, 8)}`
		+ ` local=${p == q},${p == r},${x != y}`);
}

main();
