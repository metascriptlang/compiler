// @maxrss: 30
// @stdout: ref-array-nested-vec done
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED (Array->Ref migration tail): nested value array Vec<T>[] — a reference array whose elements are VALUE arrays — leaked because the box cell's destroyFn fell to the free-only msNumberArrayDestroy fallback (no per-element recursion into each inner array). 3 coordinated fixes: (1) checker arrayElementNeedsCleanup Array→true so the box-site selects arrCType+"Destroy" (the per-type msXxxArrayArrayDestroy walker); (2) the C type name comes from a SINGLE source — arrayCTypeName (codegen/c/types.ms) — that both genArrayType (codegen) and destructorLifting registerSeqElement (transform) route through, so the walker name can never drift from the box-site reference for ANY element kind (string/number/struct/enum/tuple); proven zero-divergence vs the legacy inline rule across the full self-host; (3) codegen forward.ms isDrcLifecycleName treats a base ending "ArrayArray" as a generated hook (emit body + forward proto) — the ms-prefixed nested name no longer collides with the runtime single-level helpers (msArray/msNumberArray/…). Walker body loops calling the inner destroyer (fillBody recurses), matching the reference seq[seq[T]] per-type destructor chain (twin-probe verified). Covers string/number/struct/enum/tuple inner. Was 7.5GB @ 200k for Vec<string>[], now flat ~2.6MB drc+orc. The leak path is the C RefCell TypeInfo.destroyFn.

// Nested value array (Vec<T>[]): a reference array whose ELEMENTS are value arrays. Cleanup
// must run the inner array's per-element destroyer on each slot — not a free-only buffer wipe
// of the outer — or every inner buffer (and its heap elements) leaks. The boxed cell's
// destroyFn is the array TYPE's per-type walker, named by the SINGLE source `arrayCTypeName`
// (codegen/c/types.ms) that both genArrayType (codegen) and destructorLifting (transform)
// route through — so the walker name can never drift from the box-site reference, for ANY
// element kind. Covers string / number / struct / enum / tuple inner. Regression for the
// 7.5GB Vec<string>[] leak + the tuple/enum-inner link failures (Array->Ref migration tail).

struct Cell { buf: string; }
enum Color { Red, Green, Blue }

function bigStr(seed: string): string {
	let s = seed;
	for (let i = 0; i < 9; i = i + 1) { s = s + s; }
	return s;
}

function makeCell(seed: string): Cell {
	return { buf: bigStr(seed) };
}

function makePair(seed: string): [string, string] {
	return [bigStr(seed), bigStr(seed)];
}

function churn(): void {
	const strs: Vec<string>[] = [];
	const nums: Vec<number>[] = [];
	const cells: Vec<Cell>[] = [];
	const cols: Vec<Color>[] = [];
	const pairs: Vec<[string, string]>[] = [];
	for (let n = 0; n < 10; n = n + 1) {
		const si: Vec<string> = [];
		si.push(bigStr("s"));
		si.push(bigStr("t"));
		strs.push(si);
		const ni: Vec<number> = [];
		ni.push(n);
		ni.push(n + 1);
		nums.push(ni);
		const ci: Vec<Cell> = [];
		ci.push(makeCell("c"));
		cells.push(ci);
		const ei: Vec<Color> = [];
		ei.push(Color.Red);
		ei.push(Color.Blue);
		cols.push(ei);
		const pi: Vec<[string, string]> = [];
		pi.push(makePair("p"));
		pairs.push(pi);
	}
}

function main(): void {
	for (let m = 0; m < 200000; m = m + 1) { churn(); }
	console.log("ref-array-nested-vec done");
}

main();
