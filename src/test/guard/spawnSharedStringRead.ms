// nim-guard: two spawn threads read one string without a data race
//
// INVARIANT: a string reaches a spawn thunk as an immutable value; readers on
//   different threads only read its payload. The runtime caches ASCII-ness in
//   the payload's cap word from the read side (atomic OR), so every read of cap
//   on a payload another thread may hold must be atomic too.
//
// WHAT IT CATCHES: a plain load of cap racing another reader's cache fill
//   (msStringIsAscii, charAt, append from a shared source). Benign on current
//   hardware, a C11 data race all the same, and TSan reports it.
//
// RED MEANS: a string read path loads cap without msStrCapLoad.
//
// GUARD-TSAN

function round(i: int32): int32 {
	const s = "spawn-" + i;
	const a = spawn(() => s.length + s.charAt(0).length);
	const b = spawn(() => { let out = "x"; out += s; return out.length; });
	return await a + await b;
}

function main(): int32 {
	let total = 0;
	for (let i = 0; i < 300; i = i + 1) total = total + round(i);
	if (total != 5780) { throw "GUARD RED: total=" + total; }
	console.log("GUARD-OK");
	return 0;
}

process.exit(main());
