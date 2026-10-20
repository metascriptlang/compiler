// @stdout: push[gl s2 sl] shift[gl g0 h1 g1 s0 h2 g2 s1 d2 sl] splice[gl h0 g0 h1 g1 s0 h2 g2 s1 h3 g3 s2 d3 sl] sort[gl h0 g0 h1 g1 h2 g2 s0 s1 s2] reverse[gl h0 g0 h2 g2 s0 s2] map[gl h0 g0 h1 g1 h2 g2] for[gl g0 gl g1 gl g2 gl] fill[gl s0 s1 s2] = 9,9,9 | d1,c2,a3 | 7,7 | 1,3 | push,
// note: an array method through a Proxy<E[], H> runs the specification's steps through get, set, has and deleteProperty, a handler without traps writes the target as Reflect does, and a handler method named as the array method overrides the steps; same output on every lane (docs/LANG.md, Proxy).
let log = "";
class Logged<T> {
	get<K extends keyof T>(target: T, key: K): T[K] { log = log + " g" + short(key); return Reflect.get(target, key); }
	set<K extends keyof T>(target: T, key: K, value: T[K]): boolean { log = log + " s" + short(key); return Reflect.set(target, key, value); }
	has<K extends keyof T>(target: T, key: K): boolean { log = log + " h" + short(key); return Reflect.has(target, key); }
	deleteProperty<K extends keyof T>(target: T, key: K): boolean { log = log + " d" + short(key); return Reflect.deleteProperty(target, key); }
}
function short<K>(key: K): string { const s = `${key}`; return s == "length" ? "l" : s; }
class NoTraps {}
class PushTwice<E> {
	push(target: E[], item: E): void { log = log + "push,"; target.push(item); target.push(item); }
}
let out = "";
function step(name: string): void { out = out + name + "[" + log.trim() + "] "; log = ""; }
const xs: string[] = ["a", "b"];
const p = new Proxy(xs, new Logged<string[]>());
p.push("c"); step("push");
p.shift(); step("shift");
p.push("a"); p.push("d"); log = "";
p.splice(0, 1); step("splice");
p.sort((a: string, b: string): number => a < b ? -1 : a > b ? 1 : 0); step("sort");
p.reverse(); step("reverse");
const mapped = p.map((x: string, i: number): string => x + `${i + 1}`); step("map");
let seen = "";
for (const x of p) seen = seen + x;
step("for");
p.fill("9"); step("fill");
const ns: int32[] = [1, 2, 3];
const bare = new Proxy(ns, new NoTraps());
bare.splice(1, 1);
const twice: int32[] = [];
new Proxy(twice, new PushTwice<int32>()).push(7);
console.log(`${out}= ${xs.join(",")} | ${mapped.join(",")} | ${twice.join(",")} | ${ns.join(",")} | ${log}`);
