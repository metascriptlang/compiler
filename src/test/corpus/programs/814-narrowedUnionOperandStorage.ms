// @stdout: 3 2 x 2 5 a
// @xfail(raiser): raiser runtime error: expected an array, got value kind Object
function applyT<T>(v: T | ((prev: T) => T), cur: T): T {
	if (typeof v === "function") { return v(cur); }
	return v;
}

function lenOf(xs: string[]): int32 { return xs.length; }

function pass(v: string[] | int32): int32 {
	if (typeof v === "object") { return lenOf(v); }
	return v;
}

function firstOf(v: string[] | int32): string {
	if (typeof v === "number") { return ""; }
	const xs = v;
	return xs[0];
}

const a = applyT<int32[]>([1, 2, 3], []);
const s = applyT<string[]>((prev) => { prev.push("x"); return prev; }, ["w"]);
console.log(`${a.length} ${s.length} ${s[1]} ${pass(["a", "b"])} ${pass(5)} ${firstOf(["a"])}`);
