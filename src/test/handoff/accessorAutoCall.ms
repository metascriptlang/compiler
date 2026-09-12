// Route 15f: Checker — a distinct over a zero-parameter function is called implicitly wherever a value is read

import { strictErrorCount, hasError } from "./helpers";

const ACC = "type Accessor<T> = distinct (() => T);\n"
	+ "function makeSignal<T>(v: T): [Accessor<T>, (n: T) => void] { let cur = v; return [(() => cur) as Accessor<T>, (n: T) => { cur = n; }]; }\n"
	+ "const [c, setC] = makeSignal<number>(1);\n"
	+ "const [items, setItems] = makeSignal<number[]>([1, 2]);\n";
const PROPS = "interface Props { count: Accessor<number>; items: Accessor<number[]>; }\n"
	+ "const props: Props = { count: c, items: items };\n";
const NEEDS = "function needsStr(s: string): string { return s; }\nfunction needsNum(n: number): number { return n; }\n";
const NUM_INTO_STRING = "got number, expected string";

// ===== A bare read is the value =====

test "a value slot receives the accessor's value" {
	assert strictErrorCount(ACC + NEEDS + "const d: number = c;\nneedsNum(c);") == 0;
	assert hasError(ACC + NEEDS + "needsStr(c);", NUM_INTO_STRING);
}

test "operands, conditions, concatenation and iteration read the value" {
	assert strictErrorCount(ACC + "const e: number = c * 2;\nconst f2: boolean = c > 1;\nconst s2: string = \"\" + c;\nfor (const x of items) { const y: number = x; }") == 0;
}

test "a member read of accessor type is the value" {
	assert strictErrorCount(ACC + PROPS + NEEDS + "const m: number = props.count * 2;\nconst n: number = props.items.length;\nfunction C(p: Props): number { const { count } = p; return count + 1; }\nneedsNum(props.count);") == 0;
	assert hasError(ACC + PROPS + NEEDS + "needsStr(props.count);", NUM_INTO_STRING);
}

test "a read inside an arrow or a nested function is the value" {
	assert strictErrorCount(ACC + NEEDS + "const g = (): number => c + 1;\nfunction h(): number { function inner(): number { return c * 3; } return inner(); }\nneedsNum(g() + h());") == 0;
	assert hasError(ACC + NEEDS + "const g = () => c;\nneedsStr(g());", NUM_INTO_STRING);
}

test "the object of a member expression reads the accessor's value first" {
	assert strictErrorCount(ACC + NEEDS + "interface Pt { x: number; }\nconst [pt, setPt] = makeSignal<Pt>({ x: 1 });\nneedsNum(pt.x);\nneedsNum(items.length);") == 0;
	assert hasError(ACC + NEEDS + "interface Pt { x: number; }\nconst [pt, setPt] = makeSignal<Pt>({ x: 1 });\nneedsStr(pt.x);", NUM_INTO_STRING);
}

// ===== A callable slot receives the accessor itself =====

test "a function-typed slot, parameter or explicit call does not auto-call" {
	assert strictErrorCount(ACC + "const f: () => number = c;\nconst v: number = c();\nfunction take(g: () => number): number { return g(); }\nconst r: number = take(c);") == 0;
}

test "an Accessor slot and a nullable Accessor slot receive the accessor" {
	assert strictErrorCount(ACC + "const a2: Accessor<number> = c;\nconst o: Accessor<number> | null = c;\ninterface P2 { v?: Accessor<number> | null; }\nconst p2: P2 = { v: c };") == 0;
}

test "an optional accessor field reads only after narrowing" {
	assert hasError(ACC + "interface P2 { v?: Accessor<number> | null; }\nfunction rd(p: P2): number { return p.v * 2; }", "operand of '*' is possibly null");
	assert strictErrorCount(ACC + NEEDS + "interface P2 { v?: Accessor<number> | null; }\nfunction rd(p: P2): number { if (p.v != null) { return needsNum(p.v) + p.v * 2; } return 0; }") == 0;
}

test "an overloaded call follows the winning formal" {
	assert strictErrorCount(ACC + "function on(cb: () => number, tag: string): number { return cb(); }\nfunction on(v: number, n: number): number { return v + n; }\nconst r1: number = on(c, \"x\");\nconst r2: number = on(c, 1);") == 0;
}

// ===== Defined consequences =====

test "an unannotated alias of an accessor is a snapshot of its value" {
	assert hasError(ACC + NEEDS + "const c2 = c;\nneedsStr(c2);", NUM_INTO_STRING);
}

test "a generic parameter binds to the value" {
	assert hasError(ACC + NEEDS + "function id<T>(x: T): T { return x; }\nneedsStr(id(c));", NUM_INTO_STRING);
}
