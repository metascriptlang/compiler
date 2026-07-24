import { Map, Set, HashMap, HashSet } from "std/core/struct";

function main(): void {
	const m = new Map<int32, int32>();
	for (let i = 0; i < 8; i = i + 1) { m.set(i as int32, (i * 10) as int32); }
	let sum = 0;
	for (const k of m.toItems()) { sum = sum + m.get(k)!; }
	for (const k of m.toItems()) { m.set(k, (m.get(k)! + 1) as int32); }
	let sum2 = 0;
	for (const k of m.toItems()) { sum2 = sum2 + m.get(k)!; }

	const s = new Set<int32>();
	for (let i = 0; i < 5; i = i + 1) { s.add(i as int32); }
	s.delete(2 as int32);

	const hm = new HashMap<int32, int32>();
	for (let i = 0; i < 6; i = i + 1) { hm.set(i as int32, i as int32); }

	const hs = new HashSet<int32>();
	for (let i = 0; i < 4; i = i + 1) { hs.add(i as int32); }

	console.log(`map-guard-ok sum=${sum} sum2=${sum2} set=${s.size} hmk=${hm.keys().length} hs=${hs.size}`);
}
main();
