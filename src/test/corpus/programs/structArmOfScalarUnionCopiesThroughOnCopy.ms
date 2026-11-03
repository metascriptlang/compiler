// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: 101k1 copies=1
// @stdout: loop copies=2 dropped: 101.
// @stdout: dropped: 101 101 1.

struct K { id: int32; tag: string; }
let copies: int32 = 0;
function onCopy(this ref dest: K, src: K): void { copies += 1; dest.id = src.id + 100; dest.tag = src.tag; }
let dropped = "dropped:";
function onDestroy(this k: K): void { if (k.id != 0) dropped += ` ${k.id}`; }
function mk(id: int32): K { return { id: id, tag: "k" + id.toString() }; }

type KU = K | int32;

function show(u: KU): string {
	if (typeof u == "number") return "n" + u.toString();
	return `${u.id}${u.tag}`;
}

function copies1(): void {
	const arr: KU[] = [mk(1), 2];
	const e = arr[0];
	console.log(`${show(e)} copies=${copies}`);
	for (const x of arr) console.log(show(x));
	console.log(`loop copies=${copies} ${dropped}.`);
}

copies1();
console.log(`${dropped}.`);
