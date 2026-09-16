// bug169 — a named function stored into a function slot inside a carrier
// Symptom: a top-level named function reaching `((x: number) => number) | null` (declaration, assignment, return,
//          ternary arm, object field, array element, call argument, generic nullable formal) or a `fn | string`
//          union died in clang (`assigning to 'msClosure' from incompatible type 'double (double)'`); the same
//          function into a bare function slot, or any closure value into the carrier, ran. JS ran.
// Root cause: the carrier wraps built their payload from the raw expression, so the function-to-closure thunk
//             that a bare function slot gets never ran for the payload.
// Fix: the payload is fitted to the slot it lands in before the carrier is built, so the thunk runs on the value
//      before a Maybe or a tagged union receives it.

function double169(x: number): number { return x * 2; }
function triple169(x: number): number { return x * 3; }
function takeMaybe169(f: ((x: number) => number) | null): number {
	if (f === null) { return -1; }
	return f(5);
}
function pick169(flag: boolean): ((x: number) => number) | null {
	if (flag) { return double169; }
	return null;
}
function takeG169<T>(v: T, f: ((x: T) => T) | null): T {
	if (f !== null) { return f(v); }
	return v;
}
interface Box169 { f: ((x: number) => number) | null; }
function takeBox169(b: Box169): number { return takeMaybe169(b.f); }
const moduleSlot169: ((x: number) => number) | null = triple169;

test "bug169: a named function into a module-level nullable function constant" {
	assert takeMaybe169(moduleSlot169) === 15;
}

test "bug169: a named function into a nullable function declaration, assignment and return" {
	const h: ((x: number) => number) | null = double169;
	assert takeMaybe169(h) === 10;
	let g: ((x: number) => number) | null = null;
	assert takeMaybe169(g) === -1;
	g = triple169;
	assert takeMaybe169(g) === 15;
	assert takeMaybe169(pick169(true)) === 10;
	assert takeMaybe169(pick169(false)) === -1;
}

test "bug169: a named function as a call argument into a nullable function parameter" {
	assert takeMaybe169(double169) === 10;
	assert takeG169(4.0, double169) === 8;
}

test "bug169: a named function in a ternary arm, an object field and an array element" {
	const flag = takeMaybe169(null) < 0;
	const t: ((x: number) => number) | null = flag ? triple169 : null;
	assert takeMaybe169(t) === 15;
	const b: Box169 = { f: double169 };
	assert takeMaybe169(b.f) === 10;
	assert takeBox169({ f: triple169 }) === 15;
	const xs: (((x: number) => number) | null)[] = [double169, null];
	assert takeMaybe169(xs[0]) === 10;
	assert takeMaybe169(xs[1]) === -1;
}

test "bug169: a named function into a union with a function member" {
	const u: ((x: number) => number) | string = double169;
	let got: number = -1;
	if (typeof u === "function") { got = u(7); }
	assert got === 14;
}

type Mount169 = (tag: string, depth: number) => number;
function mount169(tag: string, depth: number): number { return tag.length + depth; }
interface Props169 { children: Mount169 | null; }
function render169(p: Props169): number {
	if (p.children !== null) { return p.children("ab", 3); }
	return -1;
}

test "bug169: a named function into a nullable alias of a function type" {
	const m: Mount169 | null = mount169;
	assert render169({ children: m }) === 5;
	assert render169({ children: mount169 }) === 5;
	assert render169({ children: null }) === -1;
}

test "bug169: closure values into the carrier keep running" {
	const k: number = 100;
	const c = (x: number): number => x + k;
	const h: ((x: number) => number) | null = c;
	assert takeMaybe169(h) === 105;
	assert takeMaybe169((x: number): number => x - 1) === 4;
	const plain: (x: number) => number = double169;
	assert takeMaybe169(plain) === 10;
}
