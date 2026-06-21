// Correctness anchor for the string self-append fix (the UAF itself is only
// deterministic under ASAN+slab-off, which the native runner doesn't use — slab masks
// it — so this guards the OUTPUT length; the heap-use-after-free was verified clean under
// `--cc=clang -DMS_SLAB_MAX=0 -fsanitize=address` drc+orc separately).
//
// `s = s + ...` with `s` as the FIRST concat operand is rewritten by stringOpLower to an
// in-place msStringAppend(&s, ...). When a later operand ALSO is `s` (`s = s + s`, or
// `s = s + sep + s`), the appended value aliases the destination: msStringPrepareAdd can
// realloc s's payload, freeing the buffer the aliased operand still points at → UAF in the
// memcpy. Fix: msStringAppend reads the preserved bytes from dest's grown buffer when src
// aliases dest (std::string::append(*this) self-safety); msStringAppendArr snapshots the
// original payload once when any element aliases dest, so a mid-element realloc can't dangle
// a later self-operand. Nim avoids the whole class by never lowering concat-to-self in place.

function main(): void {
	let r = "ab";
	for (let i = 0; i < 6; i = i + 1) { r = r + r; }          // 2 → 128 (self-append, 2-operand)
	let s = "x";
	for (let i = 0; i < 5; i = i + 1) { s = s + "-" + s; }    // 1 → 63 (self first AND last, AppendArr)
	let t = "Q";
	for (let i = 0; i < 4; i = i + 1) { t = t + t + t; }      // 1 → 81 (self ×3)
	console.log(`string-self-append r=${r.length} s=${s.length} t=${t.length}`);
}
main();
