// nim-guard: a runtime helper that allocates a managed temporary must dispose it
// through the DECREF path, never by calling the type's destroy hook directly.
//
// The hook only releases the payload the type owns; the msAllocTyped cell in front
// of it, the FUTURE/atomic routing, and the ledger's destroy count all hang off
// decref. A direct hook call therefore looks correct — values are right, ASan sees
// a still-reachable block, no fault ever fires — while every call drops one cell.
//
// Proven red by restoring the direct `msBigIntDestroy(t)` in msBigIntToInt64:
// alloc=603 destroy=302 under both drc and orc — one lost cell per
// bigint→integer conversion, against 603/603 with the decref.
//
// GUARD-BALANCE bigint
// GUARD-JS

function main(): void {
	let acc: int32 = 0;
	for (let i = 0; i < 300; i += 1) {
		const b: bigint = i as bigint;
		acc = acc + (b as int32);
	}
	const wide: bigint = 9007199254740993n;
	const asI64: int64 = wide as int64;
	const asF: float64 = (1234n) as float64;
	console.log(acc);
	console.log(asI64 > 0);
	console.log(asF == 1234.0);
	console.log("GUARD-OK");
}
main();
