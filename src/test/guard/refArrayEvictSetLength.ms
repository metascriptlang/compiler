// nim-guard: setLength() releases the elements it drops
//
// INVARIANT: an array owns a share of every element, so any eviction that does
//   not hand the element back must release it — the ownership model corpus
//   615-leakRefArrayEvict pinned for shrink and splice. `setLength` is the
//   third surface onto the same eviction: std binds the generic overload to
//   msGenericArraySetLen, a macro that lowers len and releases nothing, so a
//   ref element leaks while `arr.length = n` on the very same array does not.
//
// WHAT IT PROTECTS: this is the PLAIN family, with no atomic cell anywhere —
//   the element-type selection that picks the eviction helper has to reach the
//   counted family before it can reach the atomic one, so a regression here
//   would otherwise surface only as an atomic guard going red for the wrong
//   reason. Both shrink surfaces stand side by side so neither can be fixed
//   into the other's shape.
//
// RED MEANS setLength stopped selecting its helper by element type — run
//   /trace-nim on nativeLower's evictHelperName before touching this file.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).
// GUARD-BALANCE TOTAL

interface Plain { tag: int32; }

function shrinkBySetLength(): int32 {
	const arr: Plain[] = [{ tag: 1 }, { tag: 2 }, { tag: 3 }];
	arr.setLength(1);
	return arr[0].tag;
}

function emptyBySetLength(): int32 {
	const arr: Plain[] = [{ tag: 4 }, { tag: 5 }];
	arr.setLength(0);
	return arr.length as int32;
}

function shrinkByLengthAssign(): int32 {
	const arr: Plain[] = [{ tag: 6 }, { tag: 7 }, { tag: 8 }];
	arr.length = 2;
	return arr[0].tag + arr[1].tag;
}

function main(): int32 {
	const a = shrinkBySetLength();
	const b = emptyBySetLength();
	const c = shrinkByLengthAssign();
	console.log(`setLength=${a} empty=${b} lengthAssign=${c}`);
	if (a != 1 || b != 0 || c != 13) { return 1; }
	return 0;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
