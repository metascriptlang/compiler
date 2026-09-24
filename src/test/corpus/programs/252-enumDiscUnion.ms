// @xfail(esm): tree emit: enum member of the instantiating module is referenced inside a mono'd generic body emitted in its declaring module
// ^ the prelude std/meta/node `nodeCache` module-global box: module-level RC
// values are never destroyed at exit (open compiler-side question, test
// CLAUDE.md §3.6). Every native binary carries this survivor; the ledger only
// surfaces it when the program has other ref-array activity (the runner skips
// destroy==0 types), which this program's JSON stringify/parse provides. Same
// survivor as 302/505/609 — probe-attributed 2026-08-08: 9/9 JSON-internal
// cells balance, decode path is clean.
enum EvKind { Click, Key, Wheel }

interface ClickEv { kind: EvKind.Click; x: int32; }
interface KeyEv { kind: EvKind.Key; code: int32; }
interface WheelEv { kind: EvKind.Wheel; delta: int32; }

type Ev = ClickEv | KeyEv | WheelEv;

function describe(e: Ev): string {
	return JSON.stringify(e);
}

function main(): void {
	const a: Ev = { kind: EvKind.Click, x: 7 };
	const b: Ev = { kind: EvKind.Key, code: 42 };
	const c: Ev = { kind: EvKind.Wheel, delta: -3 };
	console.log(describe(a));
	console.log(describe(b));
	console.log(describe(c));

	const back = JSON.parse<Ev>(describe(b));
	console.log(back.ok ? "decoded" : "failed");

	const bad = JSON.parse<Ev>(`{"kind":"Nope","x":1}`);
	console.log(bad.ok ? "decoded" : "failed");

	const evs: Ev[] = [a, b, c];
	let i = 0;
	while (i < evs.length) {
		console.log(describe(evs[i]));
		i = i + 1;
	}
}
main();
