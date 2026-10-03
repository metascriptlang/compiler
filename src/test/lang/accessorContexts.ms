type Accessor<T> = distinct (() => T);

export function valueOf<T>(this a: Accessor<T>): T { return a(); }

function makeSignal<T>(v: T): [Accessor<T>, (n: T) => void] {
	let cur = v;
	return [(() => cur) as Accessor<T>, (n: T) => { cur = n; }];
}

interface AccessorMemberProps {
	count: Accessor<number>;
	items: Accessor<number[]>;
	label: string;
}

function accessorMemberTwice(p: AccessorMemberProps): number {
	const { count } = p;
	return count * 2;
}

function accessorMemberTotal(props: AccessorMemberProps): number {
	let t: number = 0;
	for (const x of props.items) { t = t + x; }
	return t + props.count + props.items.length;
}

function accessorMemberRow(item: Accessor<number>, i: Accessor<number>): number {
	return item * 10 + i;
}

function accessorStorageTake(g: () => number): number { return g(); }

function accessorStorageOn(cb: () => number, tag: string): number { return cb() + tag.length; }

function accessorStorageOn(v: number, n: number): number { return v + n; }

function accessorStorageId<T>(x: T): T { return x; }

interface AccessorStorageOpt { v?: Accessor<number> | null; }

interface PatternProps { a: number; b: string; }

interface OptionalPatternProps { a?: number | null; b: string; }

interface AccessorPatternProps { count: Accessor<number>; label: string; }

function formatPattern({ a, b }: PatternProps): string { return b + a.toString(); }

function formatDefaultPattern({ a = 5, b: bb }: OptionalPatternProps): string { return bb + a.toString(); }

const doublePattern = ({ a }: PatternProps): number => a * 2;

function applyPattern(cb: (p: PatternProps) => number): number { return cb({ a: 20, b: "x" }); }

function combinePatterns({ a }: PatternProps, { b }: PatternProps): string { return b + a.toString(); }

class PatternMethod { m({ a }: PatternProps): number { return a + 10; } }

function formatAccessorPattern({ count, label }: AccessorPatternProps): string { return label + (count + 1).toString(); }

export function renderCounter({ label, count }: { label: string; count: number }): string { return label + ":" + count.toString(); }

function captureLabel({ b }: PatternProps): () => string { return () => b + "!"; }

interface NullableAccessorQ { a?: Accessor<number> | null; b?: Accessor<string> | null; }

type NullableAccessorTh<T> = () => T;

interface NullableAccessorR { a?: NullableAccessorTh<number> | null; b?: NullableAccessorTh<string> | null; }

function nullableAccessorRead(q: NullableAccessorQ): string { if (q.b != null) { return q.b; } return "none"; }

function nullableAccessorReadA(q: NullableAccessorQ): number { if (q.a != null) { return q.a + 1; } return 0; }

function nullableAccessorCall(r: NullableAccessorR): string { if (r.b != null) { return r.b(); } return "none"; }

function nullableAccessorCallA(r: NullableAccessorR): number { if (r.a != null) { return r.a() + 1; } return 0; }

function accessorDefaultAccessor<T>(f: () => T): Accessor<T> { return f as Accessor<T>; }

interface AccessorDefaultP { a?: Accessor<number> | null; s?: Accessor<string> | null; }

function accessorDefaultReadA(p: AccessorDefaultP): number { if (p.a != null) { return p.a + 0; } return -1; }

function accessorDefaultReadS(p: AccessorDefaultP): string { if (p.s != null) { return p.s; } return "-"; }

function accessorDefaultWithDefault(p: AccessorDefaultP): number { const { a = accessorDefaultAccessor(() => 500) } = p; return a + 0; }

type ValueProtocolHandler = distinct (() => void);

function valueProtocolMk(a: Accessor<number>): Accessor<number> { return a; }

function valueProtocolAttr(v: string): string { return "static " + v; }

function valueProtocolAttr(v: Accessor<string>): string { return "dyn " + v(); }

export function valueProtocolAddTo(this n: number, x: number): number { return n + x; }

let valueProtocolHits: int32 = 0;

let valueProtocolCalls: int32 = 0;

test "accessorContexts: a destructured accessor binding is read as its value" {
	const [c, setC] = makeSignal<number>(4);
	const [items, setItems] = makeSignal<number[]>([1, 2]);
	const props: AccessorMemberProps = { count: c, items: items, label: "x" };
	assert accessorMemberTwice(props) === 8;
	setC(5);
	assert accessorMemberTwice(props) === 10;
}

test "accessorContexts: a member read of accessor type is read as its value" {
	const [c, setC] = makeSignal<number>(1);
	const [items, setItems] = makeSignal<number[]>([1, 2]);
	const props: AccessorMemberProps = { count: c, items: items, label: "x" };
	assert accessorMemberTotal(props) === 6;
	setItems([7]);
	assert accessorMemberTotal(props) === 9;
}

test "accessorContexts: accessor callback parameters are read as their values" {
	const [c, setC] = makeSignal<number>(2);
	const [i, setI] = makeSignal<number>(3);
	assert accessorMemberRow(c, i) === 23;
	setI(4);
	assert accessorMemberRow(c, i) === 24;
}

test "accessorContexts: a member callee reads the accessor's value first" {
	const [c, setC] = makeSignal<number>(12);
	const props: AccessorMemberProps = { count: c, items: makeSignal<number[]>([])[0], label: "x" };
	assert c.toString() === "12";
	assert props.count.toString() === "12";
}

test "accessorContexts: implicit accessor reads in nested closures observe the current shared cell" {
	const [count, setCount] = makeSignal<float64>(2);
	const arrow = (): float64 => count + 1;
	function nested(): float64 { function inner(): float64 { return count * 3; } return inner(); }
	const bare: () => float64 = () => count;
	for (const value of [2.0, 5.0]) {
		setCount(value);
		assert arrow() == value + 1;
		assert nested() == value * 3;
		assert bare() == value;
	}
}

test "accessorContexts: a function-typed slot receives the accessor itself" {
	const [c, setC] = makeSignal<number>(1);
	const f: () => number = c;
	setC(4);
	assert f() === 4;
}

test "accessorContexts: a callable parameter receives the accessor itself" {
	const [c, setC] = makeSignal<number>(1);
	setC(9);
	assert accessorStorageTake(c) === 9;
}

test "accessorContexts: an overloaded call follows the winning formal" {
	const [c, setC] = makeSignal<number>(1);
	assert accessorStorageOn(c, "ab") === 3;
	assert accessorStorageOn(c(), 10) === 11;
}

test "accessorContexts: a generic parameter binds to the accessor and the value read follows" {
	const [c, setC] = makeSignal<number>(1);
	const a: Accessor<number> = accessorStorageId(c);
	const v: number = accessorStorageId(c);
	setC(3);
	assert a() === 3;
	assert v === 1;
}

test "accessorContexts: an Accessor slot and a nullable Accessor field receive the accessor" {
	const [c, setC] = makeSignal<number>(1);
	const a2: Accessor<number> = c;
	const p: AccessorStorageOpt = { v: c };
	let r: number = 0;
	if (p.v != null) { r = p.v * 2; }
	setC(6);
	assert a2() === 6;
	assert r === 2;
}

test "accessorContexts: an accessor operand is read as its value" {
	const [c, setC] = makeSignal<number>(1);
	setC(c + 1);
	assert c === 2;
	setC(c * 10);
	assert c === 20;
}

test "accessorContexts: an accessor in a condition and a template literal is read as its value" {
	const [c, setC] = makeSignal<number>(3);
	let branch = "";
	if (c > 1) { branch = `big ${c}`; } else { branch = "small"; }
	assert branch === "big 3";
	setC(0);
	assert (c > 1 ? "b" : "s") === "s";
}

test "accessorContexts: an accessor of an array is iterated and indexed" {
	const [items, setItems] = makeSignal<number[]>([1, 2, 3]);
	let sum: number = 0;
	for (const x of items) { sum = sum + x; }
	assert sum === 6;
	assert items.length === 3;
	setItems([5]);
	assert items[0] === 5;
}

test "accessorContexts: an accessor of a string concatenates as its value" {
	const [name, setName] = makeSignal<string>("a");
	const s = "" + name + "!";
	assert s === "a!";
	setName("b");
	assert name + name === "bb";
}

test "accessorContexts: a function binds the pattern from the annotated parameter" {
	assert formatPattern({ a: 1, b: "x" }) === "x1";
}

test "accessorContexts: a default fills a missing field and a rename binds the alias" {
	assert formatDefaultPattern({ b: "y" }) === "y5";
	assert formatDefaultPattern({ a: 2, b: "z" }) === "z2";
}

test "accessorContexts: arrows, annotated and contextually typed" {
	assert doublePattern({ a: 4, b: "q" }) === 8;
	const viaExpr = applyPattern(({ a }) => a + 1);
	const viaBlock = applyPattern(({ a, b }) => { return a + b.length; });
	assert viaExpr === 21;
	assert viaBlock === 21;
}

test "accessorContexts: two patterns, a method and an exported function" {
	assert combinePatterns({ a: 7, b: "l" }, { a: 8, b: "r" }) === "r7";
	const c = new PatternMethod();
	assert c.m({ a: 1, b: "m" }) === 11;
	assert renderCounter({ label: "n", count: 3 }) === "n:3";
}

test "accessorContexts: an accessor field read through the pattern is the value" {
	const q: AccessorPatternProps = { count: (() => 41) as Accessor<number>, label: "n=" };
	assert formatAccessorPattern(q) === "n=42";
}

test "accessorContexts: a destructured field survives capture by a returned closure" {
	const say = captureLabel({ a: 0, b: "hey" });
	assert say() === "hey!";
}

test "accessorContexts: two nullable accessor fields read their own payloads" {
	const q: NullableAccessorQ = { a: (() => 1) as Accessor<number>, b: (() => "x") as Accessor<string> };
	assert nullableAccessorRead(q) === "x";
	assert nullableAccessorReadA(q) === 2;
	const empty: NullableAccessorQ = { a: null, b: null };
	assert nullableAccessorRead(empty) === "none";
	assert nullableAccessorReadA(empty) === 0;
}

test "accessorContexts: two nullable alias-instance fields read their own payloads" {
	const r: NullableAccessorR = { a: () => 5, b: () => "y" };
	assert nullableAccessorCall(r) === "y";
	assert nullableAccessorCallA(r) === 6;
}

test "accessorContexts: a generic call in a nullable slot carries the payload's type" {
	const p: AccessorDefaultP = { a: accessorDefaultAccessor(() => 122), s: accessorDefaultAccessor(() => "z") };
	assert accessorDefaultReadA(p) === 122;
	assert accessorDefaultReadS(p) === "z";
}

test "accessorContexts: a destructuring default in the slot's type reads the given value" {
	const given: AccessorDefaultP = { a: accessorDefaultAccessor(() => 120), s: null };
	const none: AccessorDefaultP = { a: null, s: null };
	assert accessorDefaultWithDefault(given) === 120;
	assert accessorDefaultWithDefault(none) === 500;
}

test "accessorContexts: an explicitly typed instance still flows" {
	const c = accessorDefaultAccessor<number>(() => 7);
	const p: AccessorDefaultP = { a: c, s: null };
	assert accessorDefaultReadA(p) === 7;
}

test "accessorContexts: an alias, a generic result and an array element keep the live accessor" {
	const [count, setCount] = makeSignal<number>(5);
	const d = count;
	const g = accessorStorageId(count);
	const arr = [count];
	setCount(9);
	assert d() === 9;
	assert g() === 9;
	assert arr[0]() === 9;
}

test "accessorContexts: a call result of accessor type is read as an operand" {
	const [count, setCount] = makeSignal<number>(5);
	assert valueProtocolMk(count) * 2 === 10;
}

test "accessorContexts: aliasing a handler does not run it" {
	valueProtocolHits = 0;
	const onClick = (() => { valueProtocolHits = valueProtocolHits + 1; }) as ValueProtocolHandler;
	const h = onClick;
	const hs = [onClick];
	assert valueProtocolHits === 0;
	h();
	hs[0]();
	assert valueProtocolHits === 2;
}

test "accessorContexts: an overload picks the candidate that holds the accessor" {
	const [name, setName] = makeSignal<string>("neo");
	assert valueProtocolAttr(name) === "dyn neo";
	assert valueProtocolAttr("lit") === "static lit";
}

test "accessorContexts: operands, equality, compound assignment and unary minus read the value" {
	const [count, setCount] = makeSignal<number>(5);
	assert count === 5;
	assert -count === -5;
	let t: number = 1;
	t += count;
	assert t === 6;
}

test "accessorContexts: an index, a switch and an assertion read the value" {
	const [count, setCount] = makeSignal<number>(5);
	const [ix, setIx] = makeSignal<int32>(1);
	const arr: number[] = [10, 20, 30];
	assert arr[ix] === 20;
	let s = "";
	switch (count) { case 5: s = "five"; break; default: s = "other"; }
	assert s === "five";
	const q = count as number;
	assert q === 5;
}

test "accessorContexts: a missing member and an extension argument read the value" {
	const [count, setCount] = makeSignal<number>(5);
	const [name, setName] = makeSignal<string>("neo");
	assert name.toUpperCase() === "NEO";
	const base: number = 1;
	assert base.valueProtocolAddTo(count) === 6;
	assert Math.floor(count) === 5;
}

test "accessorContexts: a boolean accessor reads in a ternary, a logical operand and a negation" {
	const [flag, setFlag] = makeSignal<boolean>(true);
	assert (flag ? 1 : 2) === 1;
	assert (flag && true) === true;
	assert !flag === false;
	setFlag(false);
	assert (flag ? 1 : 2) === 2;
}

test "accessorContexts: implicit and explicit reads call once while aliases never call" {
	valueProtocolCalls = 0;
	const counted = (() => { valueProtocolCalls = valueProtocolCalls + 1; return 5; }) as Accessor<number>;
	const al = counted;
	assert valueProtocolCalls === 0;
	const r = counted * 2 + counted;
	assert r === 15;
	assert valueProtocolCalls === 2;
	const explicit: number = counted();
	assert explicit === 5;
	assert valueProtocolCalls === 3;
}
