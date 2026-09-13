// @stdout: static generic extension done

// A generic function with a `this typeof T` receiver binds its type parameters
// from the call arguments. On C every call needs a monomorphized body; before
// the fix the call named the uninstantiated symbol and the C compile failed.

class Scale {}

struct Pair {
	left: int32;
	right: int32;
}

function smaller<T>(this typeof Scale, a: T, b: T): T {
	return a < b ? a : b;
}

function larger<T>(this typeof Pair, a: T, b: T): T {
	return a > b ? a : b;
}

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function main(): int32 {
	const small: int32 = 9;
	const big: int64 = 5000000000;
	const huge: uint64 = 18000000000000000000;
	let ok = check("class receiver int32", Scale.smaller(small, 4) == 4);
	ok = check("class receiver explicit", Scale.smaller<int32>(small, 12) == 9) && ok;
	ok = check("struct receiver int64", Pair.larger(big, big + 1) == big + 1) && ok;
	ok = check("math min int32", Math.min(small, 4) == 4) && ok;
	ok = check("math max uint64", Math.max(huge, huge - 1) == huge) && ok;
	ok = check("math min float64", Math.min(1.5, 2.5) == 1.5) && ok;
	ok = check("math min widens to float64", Math.min(small, 1.5) == 1.5) && ok;
	const clamped: int32 = Math.min(Math.max(small, 10), 20);
	ok = check("math clamp stays int32", clamped == 10) && ok;
	if (ok) { console.log("static generic extension done"); }
	return 0;
}
process.exit(main());
