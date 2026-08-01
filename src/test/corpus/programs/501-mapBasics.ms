// Parity program — std collections floor: ordered Map<K,V> (JS Map spec
// parity: insertion-ordered iteration, update-in-place keeps position).
// C implements the order-preserving table in std/core/struct.ms; JS binds
// the native Map — this program is the contract that they agree.
// Values stay ref-typed (string): a value-type V makes get() return the
// Maybe carrier of the open G1 cluster — 010-nullable owns that xfail.
// HashMap/HashSet live in 504.

function main(): void {
	const m = new Map<string, string>();
	m.set("alpha", "a1");
	m.set("beta", "b1");
	m.set("gamma", "c1");
	console.log("size=" + m.size.toString());

	const hit = m.get("beta");
	if (hit !== null) { console.log("get=" + hit); }
	const miss = m.get("nope");
	if (miss === null) { console.log("miss=null"); }

	m.set("beta", "b2");
	console.log("sizeAfterUpdate=" + m.size.toString());

	let order = "";
	for (const k of m.keys()) { order = order + k + ","; }
	console.log("keys=" + order);

	let vals = "";
	for (const v of m.values()) { vals = vals + v + ","; }
	console.log("vals=" + vals);

	let iter = "";
	for (const k of m) { iter = iter + k + ":"; }
	console.log("forof=" + iter);

	console.log("del=" + (m.delete("alpha") ? "t" : "f"));
	console.log("delMiss=" + (m.delete("alpha") ? "t" : "f"));
	console.log("sizeAfterDelete=" + m.size.toString());

	m.set("delta", "d1");
	let order2 = "";
	for (const k of m.keys()) { order2 = order2 + k + ","; }
	console.log("keysAfterReinsert=" + order2);

	m.clear();
	console.log("sizeAfterClear=" + m.size.toString());
	m.set("omega", "z1");
	const back = m.get("omega");
	if (back !== null) { console.log("reuseAfterClear=" + back); }

	let fe = "";
	m.forEach((v: string, k: string) => { fe = fe + k + "=" + v + ";"; });
	console.log("forEach=" + fe);

	const lit: Map<string, string> = { "one": "u1", "two": "u2" };
	lit["three"] = "u3";
	const two = lit["two"];
	if (two !== null) { console.log("subscript=" + two); }
	let litKeys = "";
	for (const k of lit.keys()) { litKeys = litKeys + k + ","; }
	console.log("literalOrder=" + litKeys);
}
main();
