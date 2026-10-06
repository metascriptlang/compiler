// @stdout: pairs=ann,cid sum=11 keys=ann,bob,cid,dee area=126 plain=1
// @xfail(raiser): raiser runtime error: cannot compile node kind YieldExpr at comptime — a Map is iterated through a generator, which the Raiser bytecode compiler does not compile (Map on Raiser fails on base too, see 501-mapBasics)
// note: an array pattern over a Map iterates its entries, as TypeScript and as two loop variables take `pairs` in the reference; one name keeps the keys. `continue` and `break` inside reach the next entry and the loop exit — before, a `continue` in any for-of over a generator skipped the next() call and spun forever on C, and `[k, v]` bound nothing (C: undeclared identifier, JS: undefined).
struct Point { x: int32; y: int32; }
const scores = new Map<string, int32>();
scores.set("ann", 3);
scores.set("bob", 5);
scores.set("cid", 8);
scores.set("dee", 13);
let sum: int32 = 0;
const seen: string[] = [];
for (const [name, score] of scores) {
	if (name == "bob") continue;
	if (name == "dee") break;
	seen.push(name);
	sum += score;
}
const keys: string[] = [];
for (const [name] of scores) {
	keys.push(name);
}
const points = new Map<int32, Point>();
points.set(1, { x: 2, y: 3 });
points.set(4, { x: 5, y: 6 });
let area: int32 = 0;
for (const [id, p] of points) {
	area += id * p.x * p.y;
}
let skipped: int32 = 0;
for (const name of scores) {
	if (name == "ann") { skipped += 1; continue; }
	if (name == "cid") break;
}
console.log(`pairs=${seen.join(",")} sum=${sum} keys=${keys.join(",")} area=${area} plain=${skipped}`);
