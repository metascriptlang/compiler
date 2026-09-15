// bug166 — call arguments meeting a function type were never related to their parameter
// Symptom: `takeF(5)`, `takeF("x")`, `takeF(null)` and an un-narrowed `fn | null` passed the checker into
//          `f: (x: number) => void`, and so did a lambda literal into ANY parameter — `takeN(() => 1)` into a
//          `number`, `takeF((s: string): void => {})` into `(x: number) => void`; C died in clang
//          (`passing 'int' to parameter of incompatible type 'msClosure'`) or ran with the wrong type, JS threw
//          `f is not a function`.
// Root cause: the argument loop split the relation into four kind-based branches (function formal skipped, lambda
//             literal skipped, function value into function formal, function value into non-function formal), and
//             `null` was still related to a function type as a legacy nullable kind.
// Fix: one relation per argument, as Nim's paramTypesMatchAux relates every argument through typeRel; only a
//      formal still holding a type parameter is deferred to the post-binding check when either side is a function;
//      Function is dropped from the kinds `null` fits (function types are `not nil`, NIM-REF missing-fields row).

function take166(f: (x: number) => number): number { return f(2); }
function takeMaybe166(f: ((x: number) => number) | null): number {
	if (f === null) { return -1; }
	return f(3);
}
function narrowed166(h: ((x: number) => number) | null): number {
	if (h !== null) { return take166(h); }
	return -1;
}
function double166(x: number): number { return x * 2; }
type Th166 = distinct (() => number);
interface Sink166 { cb: (f: (x: number) => number) => number; }
class Holder166 {
	run(f: (x: number) => number): number { return f(4); }
}

test "bug166: function-shaped arguments still pass and run" {
	assert take166((x: number): number => x + 1) === 3;
	assert take166((x) => x * 10) === 20;
	assert take166(double166) === 4;
	const fv = (x: number): number => x - 1;
	assert take166(fv) === 1;
}

test "bug166: a nullable function parameter takes null and functions, and narrows into a plain one" {
	assert takeMaybe166(null) === -1;
	assert takeMaybe166((x: number): number => x + 5) === 8;
	assert narrowed166((x: number): number => x * 2) === 4;
	assert narrowed166(null) === -1;
}

function pickG166<T>(x: T, f: ((a: T, b: T) => boolean) | null): boolean {
	if (f != null) { return f(x, x); }
	return false;
}

test "bug166: a generic nullable function parameter takes null and arrows once T binds" {
	assert !pickG166(3.5, null);
	assert pickG166(3.5, (a, b) => a == b);
	assert !pickG166(3.5, (a: number, b: number): boolean => a != b);
}

function eff166(f: () => void): void { f(); }
let hits166: int32 = 0;

test "bug166: value-returning and statement lambdas run through a void-returning parameter" {
	hits166 = 0;
	eff166(() => { hits166 = hits166 + 1; });
	eff166(() => hits166 + 10);
	assert hits166 === 1;
}

test "bug166: a distinct thunk widens, and field closures and methods take functions" {
	const t = (() => 7) as Th166;
	const takeT = (f: () => number): number => f();
	assert takeT(t) === 7;
	const sink: Sink166 = { cb: (f: (x: number) => number): number => f(5) };
	assert sink.cb(double166) === 10;
	const holder = new Holder166();
	assert holder.run(double166) === 8;
}
