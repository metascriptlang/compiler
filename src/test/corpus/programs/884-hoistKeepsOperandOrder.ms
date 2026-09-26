let log = "";
function a(): int32 { log = log + "a"; return 1; }
function b(): int32 { log = log + "b"; return 2; }
function s(): string { log = log + "s"; return "xy"; }
function mk(): string { log = log + "m"; return "mk"; }
function take(x: int32, y: string): int32 { return x + y.length; }
function pair(x: int32, y: int32): int32 { return x * 10 + y; }
function wrap(x: int32, y: string): string { return x.toString() + y; }

class Pt {
	x: int32;
	y: int32;
	constructor(x: int32, y: int32) { this.x = x; this.y = y; }
}

interface Named { name: string; n: int32; }

class Sym { name: string = ""; }
interface Trio { first: string; label: string; sym: Sym; }
function labelOf(sym: Sym): string { log = log + "l"; return "<" + sym.name + ">"; }
function trio(n: string): Trio {
	const first = "f" + n;
	const sym = new Sym();
	sym.name = n;
	return { first, label: labelOf(sym), sym };
}

function report(label: string, value: string): void {
	console.log(label + ": " + log + " " + value);
	log = "";
}

function run(): void {
	report("arg", take(a(), s()).toString());
	report("sum", (a() + s().length).toString());
	report("nested", pair(a(), take(b(), s())).toString());
	report("deeper", wrap(a(), wrap(b(), s())));
	const p = new Pt(a(), s().length);
	report("new", p.x.toString() + p.y.toString());
	const e: Named = { name: mk(), n: s().length };
	report("fields", e.name + e.n.toString());
	const xs: int32[] = [10, 20, 30];
	report("index", take(xs[a()], s()).toString());
	const ys: int32[] = [a(), b(), s().length];
	report("elements", ys.length.toString());
	const t = trio("k");
	report("moved", t.first + t.label + t.sym.name);
}
run();
