// Route 15f: Checker — the valueOf protocol reads a value only where resolution would otherwise fail

import { strictErrorCount, hasError } from "./helpers";

const ACC_TYPE = "type Accessor<T> = distinct (() => T);\n";
const VALUE_OF = "export function valueOf<T>(this a: Accessor<T>): T { return a(); }\n";
const SIGNALS = "function makeSignal<T>(v: T): [Accessor<T>, (n: T) => void] { let cur = v; return [(() => cur) as Accessor<T>, (n: T) => { cur = n; }]; }\n"
	+ "const [c, setC] = makeSignal<number>(1);\n"
	+ "const [items, setItems] = makeSignal<number[]>([1, 2]);\n"
	+ "const [flag, setFlag] = makeSignal<boolean>(true);\n";
const ACC = ACC_TYPE + VALUE_OF + SIGNALS;
const NO_PROTOCOL = ACC_TYPE + SIGNALS;
const PROPS = "interface Props { count: Accessor<number>; items: Accessor<number[]>; }\n"
	+ "const props: Props = { count: c, items: items };\n";
const NEEDS = "function needsStr(s: string): string { return s; }\nfunction needsNum(n: number): number { return n; }\n";
const NUM_INTO_STRING = "got number, expected string";

// ===== A read that would fail is the value =====

test "a value slot receives the accessor's value" {
	assert strictErrorCount(ACC + NEEDS + "const d: number = c;\nlet t: number = 0;\nt = c;\nfunction r(): number { return c; }\nneedsNum(c);") == 0;
	assert hasError(ACC + NEEDS + "needsStr(c);", NUM_INTO_STRING);
}

test "operands, conditions, concatenation and iteration read the value" {
	assert strictErrorCount(ACC + "const e: number = c * 2;\nconst f2: boolean = c > 1;\nconst s2: string = \"\" + c;\nfor (const x of items) { const y: number = x; }") == 0;
	assert strictErrorCount(ACC + "const u: number = -c;\nlet acc: number = 0;\nacc += c;\nconst nb: boolean = !flag;\nconst tern: number = flag ? 1 : 2;\nif (c > 0) { acc = 1; }\nwhile (flag) { break; }\nconst both: boolean = flag && true;\nif (flag) { acc = 2; }") == 0;
}

test "an index, a switch, an assertion and an equality against a value read the value" {
	assert strictErrorCount(ACC + "const [ix, setIx] = makeSignal<int32>(0);\nconst arr: number[] = [1, 2];\nconst el: number = arr[ix];\nswitch (c) { case 1: break; default: break; }\nconst q: number = c as number;\nconst eq: boolean = c === 1;\nconst sp: number[] = [...items];") == 0;
}

test "a member read of accessor type is the value" {
	assert strictErrorCount(ACC + PROPS + NEEDS + "const m: number = props.count * 2;\nconst n: number = props.items.length;\nfunction C(p: Props): number { const { count } = p; return count + 1; }\nneedsNum(props.count);") == 0;
	assert hasError(ACC + PROPS + NEEDS + "needsStr(props.count);", NUM_INTO_STRING);
}

test "a read inside an arrow or a nested function is the value" {
	assert strictErrorCount(ACC + NEEDS + "const g = (): number => c + 1;\nfunction h(): number { function inner(): number { return c * 3; } return inner(); }\nneedsNum(g() + h());") == 0;
}

test "a missing member reads the accessor's value first" {
	assert strictErrorCount(ACC + NEEDS + "interface Pt { x: number; }\nconst [pt, setPt] = makeSignal<Pt>({ x: 1 });\nneedsNum(pt.x);\nneedsNum(items.length);\nconst s3: string = c.toString();\nconst m2: number[] = items.map((x: number): number => x * 2);") == 0;
	assert hasError(ACC + NEEDS + "interface Pt { x: number; }\nconst [pt, setPt] = makeSignal<Pt>({ x: 1 });\nneedsStr(pt.x);", NUM_INTO_STRING);
}

test "an extension-method argument and a call result read the value" {
	assert strictErrorCount(ACC + "export function addTo(this n: number, x: number): number { return n + x; }\nconst base: number = 1;\nconst s5: number = base.addTo(c);\nconst fl: number = Math.floor(c);\nfunction mk(): Accessor<number> { return c; }\nconst m3: number = mk() * 2;") == 0;
}

test "an explicit valueOf call reads the value" {
	assert strictErrorCount(ACC + "const pv: number = c.valueOf();") == 0;
}

// ===== A slot that can hold the accessor receives the accessor =====

test "a function-typed slot, parameter or explicit call does not read the value" {
	assert strictErrorCount(ACC + "const f: () => number = c;\nconst v: number = c();\nfunction take(g: () => number): number { return g(); }\nconst r: number = take(c);") == 0;
}

test "an Accessor slot and a nullable Accessor slot receive the accessor" {
	assert strictErrorCount(ACC + "const a2: Accessor<number> = c;\nconst o: Accessor<number> | null = c;\ninterface P2 { v?: Accessor<number> | null; }\nconst p2: P2 = { v: c };") == 0;
}

test "an unannotated alias, a generic parameter and an array element keep the accessor" {
	assert strictErrorCount(ACC + NEEDS + "function id<T>(x: T): T { return x; }\nconst c2 = c;\nconst a3: Accessor<number> = c2;\nneedsNum(c2);\nconst a4: Accessor<number> = id(c);\nneedsNum(id(c));\nconst arr: Accessor<number>[] = [c];\nconst same: boolean = c2 === c;") == 0;
}

test "an arrow returning a bare accessor fits both a value thunk and an accessor thunk" {
	assert strictErrorCount(ACC + "const t1: () => number = () => c;\nconst t2: () => Accessor<number> = () => c;") == 0;
}

test "nullish coalescing keeps the accessor and an accessor variable rejects a value" {
	assert strictErrorCount(ACC + "function pick(nn: Accessor<number> | null): Accessor<number> { return nn ?? c; }") == 0;
	assert strictErrorCount(ACC + "let c3: Accessor<number> = c;\nc3 = 5;") > 0;
}

test "an optional accessor field reads only after narrowing" {
	assert hasError(ACC + "interface P2 { v?: Accessor<number> | null; }\nfunction rd(p: P2): number { return p.v * 2; }", "operand of '*' is possibly null");
	assert strictErrorCount(ACC + NEEDS + "interface P2 { v?: Accessor<number> | null; }\nfunction rd(p: P2): number { if (p.v != null) { return needsNum(p.v) + p.v * 2; } return 0; }") == 0;
}

test "an overloaded call takes a candidate that holds the accessor and never reads it to find one" {
	assert strictErrorCount(ACC + "function on(cb: () => number, tag: string): number { return cb(); }\nfunction on(v: number, n: number): number { return v + n; }\nconst r1: number = on(c, \"x\");") == 0;
	assert hasError(ACC + "function on(cb: () => number, tag: string): number { return cb(); }\nfunction on(v: number, n: number): number { return v + n; }\nconst r2: number = on(c, 1);", "No matching overload for 'on'");
	assert strictErrorCount(ACC + NEEDS + "function g(v: Accessor<number>): string { return \"a\"; }\nfunction g(v: number): number { return v; }\nneedsStr(g(c));") == 0;
}

// ===== The protocol is opt-in, single-step and keyed on the receiver's type name =====

test "without a valueOf declaration an accessor read is an error" {
	assert hasError(NO_PROTOCOL + NEEDS + "needsNum(c);", "got Accessor<number>, expected number");
	assert hasError(NO_PROTOCOL + "const e: number = c * 2;", "operator '*' cannot be applied to types 'Accessor<number>'");
	assert hasError(NO_PROTOCOL + "const b2: boolean = c > 1;", "operator '>' cannot be applied to types 'Accessor<number>'");
	assert hasError(NO_PROTOCOL + "const b3: boolean = c === 1;", "operator '===' cannot be applied to types 'Accessor<number>'");
	assert hasError(NO_PROTOCOL + "if (flag) { }", "a function is always truthy");
	assert hasError(NO_PROTOCOL + "const u: number = -c;", "unary '-' needs a numeric operand");
	assert hasError(NO_PROTOCOL + "let acc: number = 0;\nacc += c;", "operator '+=' cannot be applied");
	assert hasError(NO_PROTOCOL + "const [ix, setIx] = makeSignal<int32>(0);\nconst arr: number[] = [1, 2];\nconst el = arr[ix];", "an array index must be a number");
	assert hasError(NO_PROTOCOL + "switch (c) { case 1: break; default: break; }", "is not comparable to the switch value");
}

test "valueOf is applied at most once" {
	assert hasError(ACC + "function wrap<T>(f: () => T): Accessor<T> { return f as Accessor<T>; }\nconst cc = wrap(() => c);\nconst n2: number = cc;", "'Accessor<number>' is not assignable");
}

test "a distinct of the same shape under another name is not read through valueOf" {
	assert hasError(ACC + NEEDS + "type Other<T> = distinct (() => T);\nconst o = (() => 1.5) as Other<number>;\nneedsNum(o);", "got Other<number>, expected number");
}

test "aliasing a handler does not call it" {
	assert strictErrorCount(ACC + "type Handler = distinct (() => void);\nlet hits: int32 = 0;\nconst onClick = (() => { hits = hits + 1; }) as Handler;\nconst h = onClick;\nconst h2: Handler = h;\nconst hs: Handler[] = [onClick];") == 0;
}
