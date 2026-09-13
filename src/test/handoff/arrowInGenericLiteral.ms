// Route 15j: Checker — an unannotated arrow parameter inside a generic call's object literal is typed by the instantiated field

import { strictErrorCount, hasError } from "./helpers";

const COMP = "function comp<P>(f: (p: P) => number, props: P): number { return f(props); }\n"
	+ "function Row(props: { children: (x: number, i: string) => number; tag: string }): number { return props.children(1, props.tag); }\n"
	+ "function GRow<T>(props: { each: () => T[]; children: (x: T, i: string) => number }): number { return props.children(props.each()[0], \"s\"); }\n"
	+ "function needsNum(n: number): number { return n; }\nfunction needsStr(s: string): string { return s; }\n";

test "an unannotated row parameter takes the instantiated field's parameter type" {
	assert strictErrorCount(COMP + "function f(): number { return comp(Row, { children: (x, i) => needsNum(x) + needsStr(i).length, tag: \"t\" }); }") == 0;
	assert hasError(COMP + "function f(): number { return comp(Row, { children: (x, i) => needsNum(i), tag: \"t\" }); }", "got string, expected number");
}

test "a generic component passed as a value types the row from its instantiation" {
	assert strictErrorCount(COMP + "function f(): number { return comp(GRow, { each: () => [1, 2], children: (x, i) => needsNum(x) + needsStr(i).length }); }") == 0;
	assert strictErrorCount(COMP + "function f(): number { return comp(GRow, { each: (): number[] => [1, 2], children: (x: number, i) => x + needsStr(i).length }); }") == 0;
	assert hasError(COMP + "function f(): number { return comp(GRow, { each: () => [1, 2], children: (x, i) => needsNum(i) }); }", "got string, expected number");
}

test "a synthesized coercion inside the literal survives the instantiated re-check" {
	const SRC = COMP
		+ "type Vw = (h: number) => number;\n"
		+ "function Idx<T>(props: { each: () => T[]; children: (item: T, index: number) => Vw; fallback?: Vw | null }): number { const fb = props.fallback; if (fb === null) { return props.children(props.each()[0], 0)(1); } return (fb as Vw)(2); }\n"
		+ "function f(): number { return Idx<number>({ each: () => [7, 8], children: (item, i) => (h: number): number => h + item })\n"
		+ "\t+ Idx<number>({ each: () => [9], children: (item, i) => (h: number): number => h + item, fallback: (h: number): number => h * 100 }); }";
	assert strictErrorCount(SRC) == 0;
}

test "a synthesized closure wrap in a generic literal field survives the re-check" {
	const SRC = "function egEach(): number[] { return [10, 20, 30]; }\n"
		+ "function egWrap<T>(props: { each: () => T[] }): number { return props.each().length; }\n"
		+ "function f(): number { return egWrap<number>({ each: egEach }); }";
	assert strictErrorCount(SRC) == 0, "errors=" + strictErrorCount(SRC).toString();
}
