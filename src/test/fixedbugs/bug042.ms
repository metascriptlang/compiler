// bug042 — `const e = container[idx]` of Named-struct element leaked
//
// Symptom:    Generic functions that bound a struct array element to a
//             local (e.g. `const e = m.entries[slot]` inside
//             `orderedMapRawGet<K, V>`) leaked one heap-bearing entry
//             copy per call. Map.set / Map.get every iteration leaked
//             ~1.4 entries (~45 bytes), accumulating ~15 MB / 100K ops.
//             Only triggered when the entry contained heap-allocated
//             fields (string, ref). Literals masked the leak because
//             `msStringCopy` of a flagged literal is a no-op.
//
// Root cause: src/analyzer/inject.ms `passCopyToSink` synthesizes a
//             single-use `$borrow_N` temp via Copy from the source
//             container element. The caller's VarDecl init then sees
//             the borrow temp as the Identifier RHS. moveOrCopy queries
//             `isLastReadSafe` for the temp's symbol, which routes
//             through CFG analysis. The CFG was built from the original
//             function body and doesn't contain the synthesized temp —
//             so it returns `false` (not last read). moveOrCopy falls
//             to `genCopy`, emitting a SECOND deep Copy from the borrow
//             into the dest. Only the dest is destroyed at scope-exit;
//             the borrow's heap data leaks (passCopyToSink intentionally
//             skips scope cleanup since the sink consumer takes ownership).
//
// Fix:        Tag passCopyToSink-synthesized temps with the new
//             `SymbolFlag.SinkTemp` flag. `isLastReadSafe` short-circuits
//             to `true` for flagged symbols, so moveOrCopy picks
//             `genSink` (blit + wasMoved on source temp). One Copy total,
//             balanced ownership transfer, no leak.
//
// Reference:  Probed in isolation (blastJ_heapEntries): generic
//             `fn<K, V>(arr: Pair<K, V>[]) { const e = arr[i]; ... }`
//             pattern with heap-allocated struct fields leaks 1 / call
//             pre-fix, 0 / call post-fix.

struct Bug042Pair<K, V> { hcode: int64; key: K; value: V; }
class Bug042Map<K, V> {
	entries: Bug042Pair<K, V>[];
}
function bug042_lookup<K, V>(m: Bug042Map<K, V>, target: K, h: int64): boolean {
	let i = 0;
	while (i < m.entries.length) {
		const e = m.entries[i];
		if (e.hcode === h && e.key === target) { return true; }
		i = i + 1;
	}
	return false;
}

test "bug042: generic struct array element bind doesn't leak" {
	const m = new Bug042Map<string, number>();
	m.entries = [
		{ hcode: 100 as int64, key: "alice-heap-string", value: 1 },
		{ hcode: 200 as int64, key: "bob-heap-string", value: 2 },
	];
	assert bug042_lookup(m, "alice-heap-string", 100 as int64);
	assert !bug042_lookup(m, "carol", 999 as int64);
}
