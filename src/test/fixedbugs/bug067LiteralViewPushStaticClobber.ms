// bug067 — push through a string literal's byte view clobbered static memory
//
// Symptom:    `const v = "abc".asBytes(); v.push(...) × 40` silently wrote
//             past the literal's static payload and overwrote the NEXT
//             literal in the section — a later `"hello-neighbor"` printed
//             "XXXXXXXXXXXXXX". No crash, no diagnostic (macOS links the
//             payload writable). Measured in audit2 (BUGS.md §2 zero-copy
//             bridge ownership row, hole (c)).
//
// Root cause: string payload caps carry flag bits (MS_STRLIT_FLAG bit 62,
//             MS_ASCII_CHECKED/MS_ASCII_FLAG bits 61/60). The array runtime
//             read cap RAW: at the push call site the flagged cap compared as
//             astronomically large → "enough room" → in-place write to static
//             memory, and msArrayPrepareAdd/Uninit would realloc a payload
//             they don't own had they ever been reached.
//
// Fix:        Nim prepareSeqAddUninit parity — msUint8ArrayPush masks the cap
//             for its room check and diverts flagged payloads to
//             msArrayPrepareAdd/Uninit, which copy a flagged payload to a
//             fresh owned one (never realloc, never free the source; stale
//             ASCII-cache bits are dropped with the copy).
//
// ⚠ The neighbor assert relies on same-TU source-order static emission — the
// probe (audit2 rerun) proved that layout holds today. Assert via charCodeAt:
// `neighbor === "hello-neighbor"` stays TRUE under the bug (both sides read
// the same clobbered payload).

test "bug067: literal byte view push must not clobber static neighbors" {
	const v = "abc".asBytes();
	let k = 0;
	while (k < 40) {
		v.push(88);
		k = k + 1;
	}
	const neighbor = "hello-neighbor";
	assert neighbor.charCodeAt(0) === 104;
	assert neighbor.charCodeAt(13) === 114;
	assert neighbor.length === 14;
	assert v.length === 43;
	assert v[0] === 97;
	assert v[2] === 99;
	assert v[3] === 88;
	assert v[42] === 88;
}

test "bug067: heap-source byte view push still grows coherently" {
	const src = "ab" + "c";
	const v = src.asBytes();
	v.push(33);
	assert v.length === 4;
	assert v[0] === 97;
	assert v[3] === 33;
}
