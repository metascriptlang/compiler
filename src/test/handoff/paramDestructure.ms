// Route 15g: Parser + Checker — a destructured parameter binds its pattern with the fields' declared types

import { strictErrorCount, hasError } from "./helpers";

const P = "interface P { a: number; b: string; }\n";
const P2 = "interface P2 { a?: number | null; b: string; }\n";
const NEEDS = "function needsStr(s: string): string { return s; }\nfunction needsNum(n: number): number { return n; }\n";
const ACC = "type Accessor<T> = distinct (() => T);\n";
const NUM_INTO_STRING = "got number, expected string";
const STR_INTO_NUM = "got string, expected number";

test "an annotated destructured parameter binds each field with its declared type" {
	assert strictErrorCount(P + NEEDS + "function f({ a, b }: P): string { needsNum(a); return b + a.toString(); }") == 0;
	assert hasError(P + NEEDS + "function f({ a, b }: P): string { needsStr(a); return b; }", NUM_INTO_STRING);
	assert hasError(P + NEEDS + "function f({ a, b }: P): number { needsNum(b); return a; }", STR_INTO_NUM);
}

test "a default and a rename inside the pattern" {
	assert strictErrorCount(P2 + NEEDS + "function g({ a = 5, b: bb }: P2): string { needsNum(a); return bb; }") == 0;
	assert hasError(P2 + NEEDS + "function g({ b: bb }: P2): string { needsNum(bb); return bb; }", STR_INTO_NUM);
}

test "arrow functions: annotated, and contextually typed from the callback slot" {
	assert strictErrorCount(P + NEEDS + "const h = ({ a }: P): number => a * 2;\nfunction each(cb: (p: P) => number): number { return cb({ a: 1, b: \"x\" }); }\neach(({ a, b }) => { needsStr(b); return a; });\neach(({ a }) => a + 1);") == 0;
	assert hasError(P + NEEDS + "function each(cb: (p: P) => number): number { return cb({ a: 1, b: \"x\" }); }\neach(({ a, b }) => { needsStr(a); return a; });", NUM_INTO_STRING);
}

test "two destructured parameters, a method and an exported function" {
	assert strictErrorCount(P + NEEDS + "function k({ a }: P, { b }: P): string { needsNum(a); return b; }\nclass C { m({ a }: P): number { return a + 10; } }\nexport function Counter({ a, b }: P): string { return b + a.toString(); }") == 0;
}

test "an accessor field read through the pattern is the value" {
	assert strictErrorCount(ACC + "interface Q { count: Accessor<number>; label: string; }\n" + NEEDS + "function r({ count, label }: Q): string { needsNum(count); return label + (count + 1).toString(); }") == 0;
	assert hasError(ACC + "interface Q { count: Accessor<number>; label: string; }\n" + NEEDS + "function r({ count }: Q): number { needsStr(count); return 1; }", NUM_INTO_STRING);
}

test "a destructured parameter without a type annotation is refused" {
	assert hasError("function z({ a }) { return a; }", "annotation");
}
