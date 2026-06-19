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
