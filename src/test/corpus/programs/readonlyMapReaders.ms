// @stdout: a=1 b=2 ab12<a1><b2> 2 true 1 -1|x=7 y=0 xy70<x7><y0> 2 true 7 true|x=7 y=3 xy73<x7><y3> 2 true 7 true|spawned 7 -1
class Tally { n: int32 = 0; }

function nums(m: Readonly<Map<string, number>>): string {
	let s = "";
	for (const [k, v] of m) s += `${k}=${v} `;
	for (const k of m.keys()) s += k;
	for (const v of m.values()) s += `${v}`;
	m.forEach((v: number, k: string) => { s += `<${k}${v}>`; });
	return `${s} ${m.size} ${m.has("a")} ${m.get("a") ?? -1} ${m.get("z") ?? -1}`;
}

function tallies(m: Readonly<Map<string, Tally>>): string {
	let s = "";
	for (const [k, t] of m) s += `${k}=${t.n} `;
	for (const k of m.keys()) s += k;
	for (const t of m.values()) s += `${t.n}`;
	m.forEach((t: Readonly<Tally>, k: string) => { s += `<${k}${t.n}>`; });
	const hit = m.get("x");
	return `${s} ${m.size} ${m.has("x")} ${hit == null ? -1 : hit.n} ${m.get("q") == null}`;
}

async function spawned(m: Map<string, number>): Promise<string> {
	const hit = await spawn(() => m.get("c") ?? -1);
	const miss = await spawn(() => m.get("z") ?? -1);
	return `spawned ${hit} ${miss}`;
}

const m = new Map<string, number>();
m.set("a", 1);
m.set("b", 2);
const t = new Map<string, Tally>();
const x = new Tally();
x.n = 7;
t.set("x", x);
t.set("y", new Tally());
const before = tallies(t);
t.get("y")!.n = 3;
const c = new Map<string, number>();
c.set("c", 7);
console.log([nums(m), before, tallies(t), await spawned(c)].join("|"));
