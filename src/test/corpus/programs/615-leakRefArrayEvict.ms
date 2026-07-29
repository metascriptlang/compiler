// @ledger-slack(msRefArrayRefCell): 1
// @maxrss: 30
// @stdout: leak-ref-array-evict done
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED in runtime/core/array.c — the three ref/string-array element-eviction paths that dropped references. (1) msRefArrayShrink (`arr.length = n`): NULL'd evicted slots without decref; the sugar (builtinLower lowerLengthAssign → msRefArraySetLen → msRefArrayShrink) injects no compensating decref, unlike index-store (`arr[i]=x`, DRC-injected decref-old) and `.pop()` (transfers ownership to the receiver). msRefArraySetLenUninit shared the gap (partial decref skipping the element's destroyFn) — now both route through the one correct shrink. (2/3) msRefArraySplice + msStringArraySplice (`arr.splice(i,k)`): memmoved the tail over the removed elements without decref/destroy — `.splice` is a real API (std/core/array, used by asyncBridge stmts.splice). All three now free each evicted element + its owned heap fields via the canonical msDecref / msStringDestroy; msRefArrayDestroy/Shrink/Splice unified on msDecref. Ownership model: the array owns its elements (push moves in, no incref), so any eviction not handing the element back must free it. Pure-MS isolation: `.length=n` shrink = 63MB @ 1M, `.pop()`/`arr[i]=x`/scalar flat at 2MB. The Raiser VM trips shrink on every script return (vmHandleRet pops the frame array via items.length=len-1) — the leak that surfaced it; invisible to every prior native case (none shrank/spliced a ref array). Covers shrink (single + bulk) and middle-splice (ref + string). Was 63MB+, now flat.

// Reference/string array element eviction must free the evicted elements + their
// owned heap fields. Three eviction paths share one ownership rule (the array owns
// each element; push moves ownership in, so eviction that does not hand the element
// back to the caller must decref/destroy it):
//   - arr.length = n   (shrink)        → msRefArrayShrink      (NULL'd slots, no decref)
//   - arr.splice(i, k) (middle remove) → msRefArraySplice      (memmoved over, no decref)
//                                      → msStringArraySplice   (same, string elements)
// All three dropped references; index-store (arr[i]=x) and .pop() were already correct
// (DRC-injected decref-old / ownership transfer to the receiver). The Raiser VM trips
// shrink on every script function return (vmHandleRet pops the call-frame array via
// items.length=len-1) — the leak that surfaced this. Invisible to every prior
// native case (none shrank/spliced a ref array). Was 63MB+, now flat.

interface Frame { name: string; depth: number; }

function bigName(seed: string): string {
	let s = seed;
	let i = 0;
	while (i < 6) { s = s + s; i = i + 1; }
	return s;
}

function churnShrink(): void {
	const stack: Frame[] = [];
	let k = 0;
	while (k < 16) { stack.push({ name: bigName("f"), depth: k }); k = k + 1; }
	stack.length = stack.length - 1;
	stack.length = 0;
}

function churnSpliceRef(): void {
	const stack: Frame[] = [];
	let k = 0;
	while (k < 16) { stack.push({ name: bigName("f"), depth: k }); k = k + 1; }
	stack.splice(4, 8);
}

function churnSpliceStr(): void {
	const xs: string[] = [];
	let k = 0;
	while (k < 16) { xs.push(bigName("s")); k = k + 1; }
	xs.splice(2, 10);
}

// Insert-form splice(start, deleteCount, item): the array acquires a ref to the
// inserted element (borrow arg + internal incref), so a double-incref would grow
// RSS here — evicting everything must return to flat.
function churnSpliceInsert(): void {
	const stack: Frame[] = [];
	let k = 0;
	while (k < 8) { stack.push({ name: bigName("f"), depth: k }); k = k + 1; }
	const a: Frame = { name: bigName("g"), depth: 99 };
	stack.splice(2, 0, a);
	const b: Frame = { name: bigName("h"), depth: 77 };
	stack.splice(1, 1, b);
	stack.length = 0;
}

function main(): void {
	let i = 0;
	while (i < 200000) {
		churnShrink();
		churnSpliceRef();
		churnSpliceStr();
		churnSpliceInsert();
		i = i + 1;
	}
	console.log("leak-ref-array-evict done");
}

main();
