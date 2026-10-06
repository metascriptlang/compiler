// GUARD-OS bare
// GUARD-ASAN
// A freestanding realloc copies only the old block's bytes, as an allocator that knows each block's
// size does, so a grown array, Map, Set or string never copies from the block it lands in (an SBF
// program aborts on such a copy with "Overlapping copy"). RED MEANS realloc copies the new size out of
// the old block again: ASan reports memcpy-param-overlap in the arena's realloc.
function main(): void {
	const xs: int32[] = [];
	for (let i: int32 = 0; i < 100; i++) xs.push(i);
	const m = new Map<int32, int32>();
	for (let i: int32 = 0; i < 40; i++) m.set(i, i * 2);
	m.delete(3);
	m.set(3, 99);
	const s = new Set<int32>();
	for (let i: int32 = 0; i < 40; i++) s.add(i);
	s.delete(5);
	s.add(5);
	let text = "";
	for (let i: int32 = 0; i < 30; i++) text += "ab";
	let sum: int32 = 0;
	for (const x of xs) sum += x;
	const got: int32 = m.get(3) ?? 0;
	if (sum == 4950 && m.size == 40 && got == 99 && s.size == 40 && s.has(5) && text.length == 60) console.log("GUARD-OK");
}
main();
