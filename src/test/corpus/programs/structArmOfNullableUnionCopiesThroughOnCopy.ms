// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @xfail(raiser): a copy of a nullable struct-or-scalar union skips the struct's onCopy and the copy runs no onDestroy; card 2026-11-03-raiser-nullable-struct-union-copy-skips-oncopy
// @stdout: 103k3 105k5 copies=2
// @stdout: dropped: 105 5 103 3.

struct K { id: int32; tag: string; }
let copies: int32 = 0;
function onCopy(this ref dest: K, src: K): void { copies += 1; dest.id = src.id + 100; dest.tag = src.tag; }
let dropped = "dropped:";
function onDestroy(this k: K): void { if (k.id != 0) dropped += ` ${k.id}`; }
function mk(id: int32): K { return { id: id, tag: "k" + id.toString() }; }

type KW = K | string | null;
type KN = K | int32 | null;

function showW(w: KW): string {
	if (w == null) return "null";
	if (typeof w == "string") return "t" + w;
	return `${w.id}${w.tag}`;
}

function showN(n: KN): string {
	if (n == null) return "null";
	if (typeof n == "number") return "n" + n.toString();
	return `${n.id}${n.tag}`;
}

function copies2(): void {
	const ws: KW[] = [mk(3), "x", null];
	const f = ws[0];
	const ns: KN[] = [mk(5), 6, null];
	const g = ns[0];
	console.log(`${showW(f)} ${showN(g)} copies=${copies}`);
}

copies2();
console.log(`${dropped}.`);
