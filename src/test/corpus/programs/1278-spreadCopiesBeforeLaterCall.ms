// @stdout: lit=1,9 arg=1,9 lead=7,1,9 member=1,9 two=1,5,9 idx=1,9 nonlead=0:1,9 after=0,1,9 inner=1,9 earlier=1,9
// @stdout: rest=1,9 restLead=0,1,9 restTwo=1,5,9 restNested=0:1,9 method=1,9 ctor=1,9 restAfter=0,1,9
// @stdout: tuple=1,2 tail=1,7 obj=1,9
let a: int32[] = [1];
let b: int32[] = [5];
let bc: int32[][] = [[1]];
class Box { v: int32 = 1; b: int32[] = [1]; }
const box = new Box();
const o = { x: 1 };

function reset(): void {
	a = [1];
	b = [5];
	bc = [[1]];
	box.v = 1;
	box.b = [1];
	o.x = 1;
}
function m(): int32 { a.push(2); return 9; }
function mb(): int32 { a.push(2); b.push(6); return 9; }
function mi(): int32 { bc[0].push(2); return 9; }
function mm(): int32 { box.b.push(2); return 9; }
function mv(): int32 { box.v = 5; return 9; }
function mo(): int32 { o.x = 5; return 9; }
function k(): int32 { return 0; }
function f(x: int32[]): string { return x.join(","); }
function pair(x: int32, y: int32[]): string { return x.toString() + ":" + y.join(","); }
function g(...xs: int32[]): string { return xs.join(","); }
function h(x: int32, s: string): string { return x.toString() + ":" + s; }
function fixed(x: int32, y: int32): string { return x.toString() + "," + y.toString(); }
class Holder {
	items: int32[];
	constructor(...xs: int32[]) { this.items = xs; }
	pick(...xs: int32[]): string { return xs.join(","); }
}

function row(): string {
	reset();
	const lit = [...a, m()].join(",");
	reset();
	const arg = f([...a, m()]);
	reset();
	const lead = [7, ...a, m()].join(",");
	reset();
	const member = [...box.b, mm()].join(",");
	reset();
	const two = [...a, ...b, mb()].join(",");
	reset();
	const idx = [...bc[0], mi()].join(",");
	reset();
	const nonlead = pair(k(), [...a, m()]);
	reset();
	const after = [k(), ...a, m()].join(",");
	reset();
	const inner = [...a, ...[m()]].join(",");
	reset();
	const earlier = [box.v, mv()].join(",");
	return "lit=" + lit + " arg=" + arg + " lead=" + lead + " member=" + member + " two=" + two + " idx=" + idx
		+ " nonlead=" + nonlead + " after=" + after + " inner=" + inner + " earlier=" + earlier;
}

function callRow(): string {
	reset();
	const rest = g(...a, m());
	reset();
	const restLead = g(0, ...a, m());
	reset();
	const restTwo = g(...a, ...b, mb());
	reset();
	const restNested = h(k(), g(...a, m()));
	reset();
	const method = new Holder(1).pick(...a, m());
	reset();
	const ctor = new Holder(...a, m()).items.join(",");
	reset();
	const restAfter = g(k(), ...a, m());
	return "rest=" + rest + " restLead=" + restLead + " restTwo=" + restTwo + " restNested=" + restNested
		+ " method=" + method + " ctor=" + ctor + " restAfter=" + restAfter;
}

function controls(): string {
	reset();
	const t: [int32, int32] = [1, 2];
	const tuple = fixed(...t);
	const tail = g(...a, 7);
	const r = { ...o, k: mo() };
	return "tuple=" + tuple + " tail=" + tail + " obj=" + r.x.toString() + "," + r.k.toString();
}

console.log(row());
console.log(callRow());
console.log(controls());
