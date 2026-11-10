// @skip-js: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: held 0 42
// @stdout: dropped 1
class Probe {
	n: int32;
	constructor(n: int32) { this.n = n; }
}
let dropped = 0;
function onDestroy(this p: Probe): void { dropped += 1; }

struct Ent { k: int64; v: () => int32; }

function put(a: Ent[], sink v: () => int32): void {
	if (a.length > 0) {
		a[0].v = v;
		return;
	}
	a.push({ k: 1, v: v });
}

function fill(a: Ent[], n: int32): void {
	const p = new Probe(n);
	put(a, (): int32 => p.n + 1);
	put(a, (): int32 => p.n + 2);
}

function run(): void {
	const a: Ent[] = [];
	fill(a, 40);
	console.log("held", dropped, a[0].v().toString());
}

run();
console.log("dropped", dropped);
