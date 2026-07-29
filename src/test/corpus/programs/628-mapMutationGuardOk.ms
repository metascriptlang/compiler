// @maxrss: 30
// @stdout: map-guard-ok sum=280 sum2=288 set=4 hmk=6 hs=4
// @skip-js: migrated from native/ — JS-lane audit pending
// note: Positive half of the Map/Set concurrent-access guard (#188, Go writing-flag model). Exercises all four containers + a single-threaded mutate-during-iterate (value-update of each key while ranging m.toItems()). That must NOT fire — Go allows single-threaded mutation during range (the `writing` flag is set only for the duration of one op and clears before the iterator resumes), so this pins that the guard does not over-fire on legitimate sequential code. The guard\'s msMapFatal/exit only runs in the native binary only runs in the native binary.

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
