// FIXED in std/core/struct.ms hashSetEnlarge: the rehash loop wrote through the
// LOCAL `newData` after `s.data = newData` — under the C backend's value-array
// field assignment that store is a deep copy, so the rehash filled a dead local
// and every enlarge silently EMPTIED the live table: all prior keys lost, size
// counting phantoms, and heavy users degrade into runaway growth on garbage
// tables. hashMapEnlarge/orderedMapEnlarge/orderedSetEnlarge write through the
// field — hashSetEnlarge now mirrors them. Only the C backend's value-array
// copy makes the store a deep copy, so msc stage-2 hit it through the
// gen-destroy-hook name registry (HashSet<string>) as a probe-loop hang /
// range-error / segfault. The marker only prints if every key survives
// all enlarges and size is honest.

function main(): void {
	const seen = new HashSet<string>();
	const n = 5000;
	for (let i = 0; i < n; i++) {
		seen.add(`name-${i}-mono`);
	}
	let missing = 0;
	for (let i = 0; i < n; i++) {
		if (!seen.has(`name-${i}-mono`)) { missing = missing + 1; }
	}
	if (missing === 0 && seen.size === n) {
		console.log(`hashset-enlarge-keep ok n=${n}`);
	} else {
		console.log(`hashset-enlarge-keep MISSING=${missing} size=${seen.size}`);
	}
}
main();
