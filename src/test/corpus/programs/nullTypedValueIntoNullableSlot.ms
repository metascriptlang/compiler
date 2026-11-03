// @stdout: arg 0 0 0 0 0
// @stdout: decl 0 0 0 0
// @stdout: assign 0 0 0 0
// @stdout: return 0 0
// @stdout: order a b calls 10
function isNullNumber(a: number | null): number { return a == null ? 0 : 1; }
function isNullString(a: string | null): number { return a == null ? 0 : 1; }
function both(a: number | null, b: string | null): number { return (a == null ? 0 : 1) + (b == null ? 0 : 2); }
function id<U>(u: U): U { return u; }

let calls = 0;
const trail: string[] = [];
function nothing(tag: string): null {
	calls += 1;
	trail.push(tag);
	return null;
}
function at(): number {
	calls += 1;
	return 1;
}

function numberOf(arr: null[]): number | null { return arr[at()]; }
function stringOf(): string | null { return nothing("r"); }

function main(): void {
	const arr = [null, null];
	console.log("arg", isNullNumber(arr[0]), isNullString(arr[at()]), isNullNumber(id(null)), isNullString(nothing("x")), both(arr[1], id(null)));
	const n: number | null = arr[at()];
	const s: string | null = id(null);
	const m: number | null = nothing("y");
	const t: string | null = arr[0];
	console.log("decl", isNullNumber(n), isNullString(s), isNullNumber(m), isNullString(t));
	let a: number | null = 5;
	let b: string | null = "set";
	a = arr[at()];
	b = nothing("z");
	const ra = isNullNumber(a);
	a = 7;
	a = id(null);
	console.log("assign", ra, isNullString(b), isNullNumber(a), isNullString(arr[0]));
	console.log("return", isNullNumber(numberOf(arr)), isNullString(stringOf()));
	trail.length = 0;
	const pair = both(nothing("a"), nothing("b"));
	console.log("order", trail.join(" "), "calls", calls + pair);
}

main();
