// Route 15i: Checker — an extension generic instantiates after its arguments bind the rest

import { strictErrorCount, hasError } from "./helpers";

const EXT = "function mapIt<T, U>(this arr: T[], fn: (x: T, i: number) => U): U[] { const out: U[] = []; let i = 0; while (i < arr.length) { out.push(fn(arr[i], i)); i = i + 1; } return out; }\n"
	+ "function tagIt<T, U>(this arr: T[], u: U): U[] { const out: U[] = [u]; return out; }\n"
	+ "function firstIt<T>(this arr: T[]): T { return arr[0]; }\n";

test "a type parameter bound only by the callback's return type instantiates" {
	assert strictErrorCount(EXT + "function f(xs: number[]): string[] { return xs.mapIt((x: number, i: number): string => \"\" + x); }") == 0;
	assert strictErrorCount(EXT + "function f(xs: number[]): number[] { return xs.mapIt((x: number): number => x * 2); }") == 0;
}

test "a type parameter bound by a plain argument instantiates, a receiver-only one still does" {
	assert strictErrorCount(EXT + "function f(xs: number[]): string[] { return xs.tagIt(\"s\"); }") == 0;
	assert strictErrorCount(EXT + "function f(xs: number[]): number { return xs.firstIt(); }") == 0;
}

test "the callback's return still types the call result" {
	assert hasError(EXT + "function f(xs: number[]): number[] { return xs.mapIt((x: number): string => \"\" + x); }", "string");
}
