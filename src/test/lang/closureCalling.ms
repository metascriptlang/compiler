function genericClosureApplyN<T>(n: int32, init: T, f: (acc: T) => T): T {
	let acc: T = init;
	let i: int32 = 0 as int32;
	while (i < n) {
		acc = f(acc);
		i = (i + (1 as int32)) as int32;
	}
	return acc;
}

function curriedCaptureMakeCurried(x: int32): (y: int32) => (z: int32) => int32 {
	return (y) => (z) => (x + y + z) as int32;
}

function curriedCaptureMakeTriple(x: int32): (y: int32) => (z: int32) => (w: int32) => int32 {
	return (y) => (z) => (w) => (x + y + z + w) as int32;
}

type Opaque = unknown;

class Cell {
	id: number;
	fn: () => void;
	constructor(id: number) {
		this.id = id;
		this.fn = () => {};
	}
}

interface Kit {
	make: (n: number) => Opaque;
	readId: (c: Opaque) => number;
}

function kit(): Kit {
	return {
		make: (n: number): Opaque => {
			const c = new Cell(n);
			return c as unknown as Opaque;
		},
		readId: (c: Opaque): number => (c as unknown as Cell).id,
	};
}

function buildDeclared(k: Kit): Opaque {
	return k.make(11);
}

let voidInstantiationHits: float64 = 0;

function voidInstantiationRunId<T>(fn: (tag: number) => T): T {
	const result = fn(7);
	return result;
}

function voidInstantiationRunDirect<T>(fn: (tag: number) => T): T {
	return fn(3);
}

function voidInstantiationRoot<T>(fn: (dispose: () => void) => T): T {
	const cleanup = () => { voidInstantiationHits = voidInstantiationHits + 100; };
	const result = fn(cleanup);
	return result;
}

function expressionCaptureCall<T>(fn: () => T): T { return fn(); }

type DistinctParameterAcc<T> = distinct (() => T);

function distinctParameterAcc<T>(f: () => T): DistinctParameterAcc<T> {
	return f as DistinctParameterAcc<T>;
}

function readThrough(a: DistinctParameterAcc<number>): number {
	return a() + 1;
}

function functionFormalTake(f: (x: number) => number): number { return f(2); }

function functionFormalTakeMaybe(f: ((x: number) => number) | null): number {
	if (f === null) { return -1; }
	return f(3);
}

function functionFormalNarrowed(h: ((x: number) => number) | null): number {
	if (h !== null) { return functionFormalTake(h); }
	return -1;
}

function functionFormalDouble(x: number): number { return x * 2; }

type FunctionFormalTh = distinct (() => number);

interface FunctionFormalSink { cb: (f: (x: number) => number) => number; }

class FunctionFormalHolder {
	run(f: (x: number) => number): number { return f(4); }
}

function functionFormalPickG<T>(x: T, f: ((a: T, b: T) => boolean) | null): boolean {
	if (f != null) { return f(x, x); }
	return false;
}

function functionFormalEff(f: () => void): void { f(); }

let functionFormalHits: int32 = 0;

test "closureCalling: generic call with explicit type args + capturing closure compiles and runs" {
	const factor: int32 = 3 as int32;
	const r = genericClosureApplyN<int32>(4 as int32, 1 as int32, (x) => (x * factor) as int32);
	assert r == 81;
}

test "closureCalling: generic call with non-capturing closure also works" {
	const r = genericClosureApplyN<int32>(3 as int32, 2 as int32, (x) => (x + (10 as int32)) as int32);
	assert r == 32;
}

test "closureCalling: curried arrow with outer capture compiles and runs" {
	const f = curriedCaptureMakeCurried(100 as int32);
	const g = f(20 as int32);
	assert g(3 as int32) == 123;
}

test "closureCalling: triple-nested curried arrow with outer capture" {
	const f = curriedCaptureMakeTriple(1000 as int32);
	const g = f(100 as int32);
	const h = g(10 as int32);
	assert h(1 as int32) == 1111;
}

test "closureCalling: distinct env per top-level call (no shared state)" {

	const f1 = curriedCaptureMakeCurried(100 as int32);
	const f2 = curriedCaptureMakeCurried(200 as int32);
	const g1 = f1(20 as int32);
	const g2 = f2(20 as int32);
	assert g1(3 as int32) == 123;
	assert g2(3 as int32) == 223;
}

test "closureCalling: declared function result reaches a closure param intact" {
	const k = kit();
	const d = buildDeclared(k);
	assert k.readId(d) == 11, "declared: got " + k.readId(d).toString();
}

test "closureCalling: lambda with an explicit unknown return reaches a closure param intact" {
	const k = kit();
	const build = (kk: Kit): unknown => {
		return kk.make(22);
	};
	const d = build(k);
	assert k.readId(d) == 22, "explicit unknown: got " + k.readId(d).toString();
}

test "closureCalling: lambda annotated with an alias of unknown reaches a closure param intact" {
	const k = kit();
	const build = (kk: Kit): Opaque => {
		return kk.make(33);
	};
	const d = build(k);
	assert k.readId(d) == 33, "alias annotation: got " + k.readId(d).toString();
}

test "closureCalling: lambda with an INFERRED unknown return reaches a closure param intact" {
	const k = kit();
	const build = (kk: Kit) => {
		return kk.make(44);
	};
	const d = build(k);
	assert k.readId(d) == 44, "inferred: got " + k.readId(d).toString();
}

test "closureCalling: function expression with an unknown return reaches a closure param intact" {
	const k = kit();
	const build = function (kk: Kit): Opaque {
		return kk.make(55);
	};
	const d = build(k);
	assert k.readId(d) == 55, "function expression: got " + k.readId(d).toString();
}

test "closureCalling: lambda result survives being stored and read twice" {
	const k = kit();
	const build = (kk: Kit): Opaque => kk.make(66);
	const d = build(k);
	assert k.readId(d) == 66, "first read: got " + k.readId(d).toString();
	assert k.readId(d) == 66, "second read: got " + k.readId(d).toString();
}

test "closureCalling: lambda typed by CONTEXT reaches a closure param intact" {
	const k = kit();
	const build: (kk: Kit) => Opaque = (kk) => kk.make(77);
	const d = build(k);
	assert k.readId(d) == 77, "contextual: got " + k.readId(d).toString();
}

test "closureCalling: unknown-annotated lambda PARAM relays to a closure param intact" {
	const k = kit();
	const relay = (kk: Kit, c: unknown): number => kk.readId(c);
	const d = k.make(88);
	assert relay(k, d) == 88, "param relay: got " + relay(k, d).toString();
}

test "closureCalling: nested lambda returning unknown reaches a closure param intact" {
	const k = kit();
	const outer = (kk: Kit): Opaque => {
		const inner = (n: number): Opaque => kk.make(n);
		return inner(99);
	};
	const d = outer(k);
	assert k.readId(d) == 99, "nested: got " + k.readId(d).toString();
}

test "closureCalling: T=void instance with identifier return runs the callback" {
	voidInstantiationHits = 0;
	voidInstantiationRunId((tag: number) => { voidInstantiationHits = voidInstantiationHits + tag; });
	assert voidInstantiationHits == 7;
}

test "closureCalling: T=void instance with direct call return runs the callback" {
	voidInstantiationHits = 0;
	voidInstantiationRunDirect((tag: number) => { voidInstantiationHits = voidInstantiationHits + tag; });
	assert voidInstantiationHits == 3;
}

test "closureCalling: createRoot shape — void body receiving a dispose callback" {
	voidInstantiationHits = 0;
	voidInstantiationRoot((dispose: () => void) => {
		voidInstantiationHits = voidInstantiationHits + 1;
		dispose();
	});
	assert voidInstantiationHits == 101;
}

test "closureCalling: control — the same generics at T=number still return values" {
	voidInstantiationHits = 0;
	const a = voidInstantiationRunId((tag: number) => tag + 35);
	const b = voidInstantiationRunDirect((tag: number) => tag * 2);
	const c = voidInstantiationRoot((dispose: () => void) => { dispose(); return 9; });
	assert a == 42;
	assert b == 6;
	assert c == 9;
	assert voidInstantiationHits == 100;
}

test "closureCalling: expr-bodied arrow, inner captures enclosing const" {
	const x = 5;
	const producer = () => expressionCaptureCall(() => x + 1);
	assert producer() == 6, "const capture";
}

test "closureCalling: expr-bodied arrow, inner captures the outer arrow's param" {
	const apply = (v: number): number => expressionCaptureCall(() => v + 1);
	assert apply(5) == 6, "param capture";
}

test "closureCalling: inner arrow mutates the captured binding across calls" {
	let expressionCaptureN = 0;
	const bump = () => expressionCaptureCall(() => { expressionCaptureN = expressionCaptureN + 1; return expressionCaptureN; });
	assert bump() == 1, "first bump";
	assert bump() == 2, "second bump";
}

test "closureCalling: two nested expr-bodied arrows, innermost captures outermost const" {
	const x = 10;
	const outer = () => expressionCaptureCall(() => expressionCaptureCall(() => x + 1));
	assert outer() == 11, "double nesting";
}

test "closureCalling: no-capture control" {
	const producer = () => expressionCaptureCall(() => 6);
	assert producer() == 6, "control";
}

test "closureCalling: a callback with a plain closure parameter runs through a distinct-typed slot" {
	const cb: (a: () => number) => number = (a) => a() + 1;
	const slot: (a: DistinctParameterAcc<number>) => number = cb;
	assert slot(distinctParameterAcc(() => 41)) == 42;
}

test "closureCalling: a function declared with the distinct parameter takes the same closure by value" {
	const viaSlot: (a: DistinctParameterAcc<number>) => number = readThrough;
	assert viaSlot(distinctParameterAcc(() => 9)) == 10;
	assert readThrough(distinctParameterAcc(() => 1)) == 2;
}

test "closureCalling: function-shaped arguments still pass and run" {
	assert functionFormalTake((x: number): number => x + 1) === 3;
	assert functionFormalTake((x) => x * 10) === 20;
	assert functionFormalTake(functionFormalDouble) === 4;
	const fv = (x: number): number => x - 1;
	assert functionFormalTake(fv) === 1;
}

test "closureCalling: a nullable function parameter takes null and functions, and narrows into a plain one" {
	assert functionFormalTakeMaybe(null) === -1;
	assert functionFormalTakeMaybe((x: number): number => x + 5) === 8;
	assert functionFormalNarrowed((x: number): number => x * 2) === 4;
	assert functionFormalNarrowed(null) === -1;
}

test "closureCalling: a generic nullable function parameter takes null and arrows once T binds" {
	assert !functionFormalPickG(3.5, null);
	assert functionFormalPickG(3.5, (a, b) => a == b);
	assert !functionFormalPickG(3.5, (a: number, b: number): boolean => a != b);
}

test "closureCalling: value-returning and statement lambdas run through a void-returning parameter" {
	functionFormalHits = 0;
	functionFormalEff(() => { functionFormalHits = functionFormalHits + 1; });
	functionFormalEff(() => ++functionFormalHits);
	assert functionFormalHits === 2;
}

test "closureCalling: a distinct thunk widens, and field closures and methods take functions" {
	const t = (() => 7) as FunctionFormalTh;
	const takeT = (f: () => number): number => f();
	assert takeT(t) === 7;
	const sink: FunctionFormalSink = { cb: (f: (x: number) => number): number => f(5) };
	assert sink.cb(functionFormalDouble) === 10;
	const holder = new FunctionFormalHolder();
	assert holder.run(functionFormalDouble) === 8;
}
