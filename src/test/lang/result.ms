// Language tests: Result<T,E> + try operator

type DivResult = Result<number, string>;

function divide(a: number, b: number): DivResult {
	if (b == 0) return Result.err("division by zero");
	return Result.ok(a / b);
}

function halfDivide(a: number, b: number): DivResult {
	const val = try divide(a, b);
	return Result.ok(val / 2);
}

function safeDivide(a: number, b: number): number {
	const val = try divide(a, b) catch 0;
	return val;
}

function chain(a: number, b: number, c: number): DivResult {
	const r1 = try divide(a, b);
	const r2 = try divide(r1, c);
	return Result.ok(r2);
}

test "basic Result ok" {
	const r = divide(10, 2);
	assert r.ok == true;
	assert r.value == 5;
}

test "basic Result err" {
	const r = divide(10, 0);
	assert r.ok == false;
	assert r.error == "division by zero";
}

test "try operator ok" {
	const r = halfDivide(20, 4);
	assert r.ok == true;
	assert r.value == 2.5;
}

test "try operator err propagation" {
	const r = halfDivide(10, 0);
	assert r.ok == false;
	assert r.error == "division by zero";
}

test "try catch fallback" {
	assert safeDivide(10, 2) == 5;
	assert safeDivide(10, 0) == 0;
}

test "Result chain ok" {
	const r = chain(100, 2, 5);
	assert r.ok == true;
	assert r.value == 10;
}

test "Result chain first err" {
	const r = chain(100, 0, 5);
	assert r.ok == false;
}

test "Result chain second err" {
	const r = chain(100, 2, 0);
	assert r.ok == false;
}

test "manual Result check" {
	const r = divide(42, 7);
	if (r.ok) {
		assert r.value == 6;
	}
}

// try inside Result<void, E> — error path must propagate as Result<void, E>, not Result<T, E>
function doWork(): Result<number, string> {
	return Result.ok(42);
}

function process(): Result<void, string> {
	const val = try doWork();
	console.log("got value");
	return Result.ok(null);
}

test "try inside Result void fn ok" {
	const r = process();
	assert r.ok == true;
}

function failWork(): Result<number, string> {
	return Result.err("oops");
}

function failProcess(): Result<void, string> {
	const val = try failWork();
	return Result.ok(null);
}

test "try inside Result void fn err propagation" {
	const r = failProcess();
	assert r.ok == false;
	assert r.error == "oops";
}

// Nested: outer Result<void, E>, inner Result<number, E>
function innerCalc(): Result<number, string> {
	const x = try doWork();
	return Result.ok(x + 1);
}

function outerVoid(): Result<void, string> {
	const n = try innerCalc();
	console.log("nested ok");
	return Result.ok(null);
}

test "try nested functions different Result types" {
	const r = outerVoid();
	assert r.ok == true;
}

// =====================================================================
// Edge cases — added under the DU+Result migration test coverage push.
// =====================================================================

// --- Result<T, T> — same type for ok and err ---
function classifyInt(n: number): Result<number, number> {
	if (n >= 0) return Result.ok(n);
	return Result.err(-n);
}

test "Result<T, T> — same ok/err type" {
	const a = classifyInt(7);
	const b = classifyInt(-9);
	assert a.ok && b.ok == false;
	if (a.ok) assert a.value == 7;
	if (!b.ok) assert b.error == 9;
}

// --- Nested Result<Result<T, E1>, E2> ---
function nested(x: number): Result<Result<number, string>, string> {
	if (x < 0) return Result.err("outer fail");
	if (x == 0) return Result.ok(Result.err("inner fail"));
	return Result.ok(Result.ok(x));
}

test "Nested Result — outer ok, inner ok" {
	const r = nested(5);
	assert r.ok;
	if (r.ok) {
		const inner = r.value;
		assert inner.ok;
		if (inner.ok) assert inner.value == 5;
	}
}

test "Nested Result — outer ok, inner err" {
	const r = nested(0);
	assert r.ok;
	if (r.ok) {
		const inner = r.value;
		assert !inner.ok;
		if (!inner.ok) assert inner.error == "inner fail";
	}
}

test "Nested Result — outer err" {
	const r = nested(-1);
	assert !r.ok;
	if (!r.ok) assert r.error == "outer fail";
}

// --- Result with reference type payload ---
interface Person { name: string; age: number }

function makePerson(name: string, age: number): Result<Person, string> {
	if (age < 0) return Result.err("invalid age");
	return Result.ok({ name, age });
}

test "Result<Ref<Struct>, string> — ok variant carries reference" {
	const r = makePerson("Alice", 30);
	assert r.ok;
	if (r.ok) {
		assert r.value.name == "Alice";
		assert r.value.age == 30;
	}
}

test "Result<Ref<Struct>, string> — err variant" {
	const r = makePerson("Bob", -1);
	assert !r.ok;
	if (!r.ok) assert r.error == "invalid age";
}

// --- Result with array payload ---
function makeRange(n: number): Result<number[], string> {
	if (n < 0) return Result.err("negative count");
	const arr: number[] = [];
	let i = 0;
	while (i < n) {
		arr.push(i);
		i = i + 1;
	}
	return Result.ok(arr);
}

test "Result<number[], string> — ok with non-empty array" {
	const r = makeRange(3);
	assert r.ok;
	if (r.ok) {
		assert r.value.length == 3;
		assert r.value[0] == 0;
		assert r.value[2] == 2;
	}
}

test "Result<number[], string> — ok with empty array" {
	const r = makeRange(0);
	assert r.ok;
	if (r.ok) assert r.value.length == 0;
}

test "Result<number[], string> — err variant" {
	const r = makeRange(-5);
	assert !r.ok;
	if (!r.ok) assert r.error == "negative count";
}

// --- Result with string payload — ensure RC managed correctly ---
function buildMessage(name: string, ok: boolean): Result<string, string> {
	if (ok) return Result.ok("hello, " + name);
	return Result.err("rejected: " + name);
}

test "Result<string, string> — ok with concatenated payload" {
	const r = buildMessage("world", true);
	assert r.ok;
	if (r.ok) assert r.value == "hello, world";
}

test "Result<string, string> — multiple instances in same scope (DRC stress)" {
	const a = buildMessage("a", true);
	const b = buildMessage("b", false);
	const c = buildMessage("c", true);
	if (a.ok) assert a.value == "hello, a";
	if (!b.ok) assert b.error == "rejected: b";
	if (c.ok) assert c.value == "hello, c";
}

// --- Result + try chain that traverses through 3 functions ---
function step1(x: number): Result<number, string> {
	if (x == 0) return Result.err("step1 fail");
	return Result.ok(x * 2);
}

function step2(x: number): Result<number, string> {
	const a = try step1(x);
	if (a > 100) return Result.err("step2 overflow");
	return Result.ok(a + 1);
}

function step3(x: number): Result<number, string> {
	const a = try step2(x);
	return Result.ok(a * a);
}

test "try chain — 3 levels deep, ok path" {
	const r = step3(3);  // step1: 6 → step2: 7 → step3: 49
	assert r.ok;
	if (r.ok) assert r.value == 49;
}

test "try chain — fail at step1 propagates through all" {
	const r = step3(0);
	assert !r.ok;
	if (!r.ok) assert r.error == "step1 fail";
}

test "try chain — fail at step2 propagates" {
	const r = step3(60);  // step1: 120 → step2 overflow
	assert !r.ok;
	if (!r.ok) assert r.error == "step2 overflow";
}

// --- Result coexistence with user-defined boolean DU (regression for type-cache collision) ---
type EitherT<L, R> = match (ok: boolean) {
	true => { value: R },
	false => { error: L },
};

function eitherSplit(n: number): EitherT<string, number> {
	if (n < 0) return { ok: false, error: "negative" };
	return { ok: true, value: n };
}

test "Result + user-defined Either coexistence (cache collision regression)" {
	// Same module references Result<number, string> AND EitherT<string, number>.
	// Their variant shapes are byte-identical. Codegen must emit DISTINCT
	// outer typedefs (Result__number_string and EitherT__string_number).
	const r = step1(3);
	const e = eitherSplit(3);
	assert r.ok && e.ok;
	if (r.ok) assert r.value == 6;
	if (e.ok) assert e.value == 3;
}

// --- Result.ok(null) for Result<void, E> construction ---
test "Result.ok(null) void construction" {
	const r: Result<void, string> = Result.ok(null);
	assert r.ok;
}

test "Result.err for Result<void, E>" {
	const r: Result<void, string> = Result.err("boom");
	assert !r.ok;
	if (!r.ok) assert r.error == "boom";
}

// --- a binding copied from a narrowed Result keeps the narrowed variant ---
struct CopyKey {
	b: uint8;
}

function copyPick(flag: boolean): Result<CopyKey, string> {
	if (!flag) return Result.err("bad");
	return Result.ok({ b: 9 });
}

function copyViaParam(r: Result<CopyKey, string>): int32 {
	if (r.ok) {
		const h = r;
		return h.value.b as int32;
	}
	return -1;
}

function copyWidth(r: Result<CopyKey, string>): int32 {
	if (r.ok) return r.value.b as int32;
	return 0;
}

function copyForward(r: Result<string, int32>): Result<string, int32> {
	if (r.ok) {
		const h = r;
		const q: Result<string, int32> = h;
		return q;
	}
	const e = r;
	return e;
}

function copyText(r: Result<string, int32>): string {
	if (r.ok) {
		let h = r;
		return h.value;
	}
	return "none";
}

test "const copy of a narrowed Result reads the variant field" {
	const got = copyPick(true);
	let seen = 0;
	if (got.ok) {
		const h = got;
		seen = h.value.b as int32;
	}
	assert seen == 9;
}

test "let copy of a narrowed Result reads the variant field" {
	const got = copyPick(true);
	let seen = 0;
	if (got.ok) {
		let h = got;
		seen = h.value.b as int32;
	}
	assert seen == 9;
}

test "copy of a narrowed Result parameter reads the variant field" {
	assert copyViaParam(copyPick(true)) == 9;
	assert copyViaParam(copyPick(false)) == -1;
}

test "copy of the error arm reads error" {
	const bad = copyPick(false);
	let seen = "";
	if (!bad.ok) {
		const h = bad;
		seen = h.error;
	}
	assert seen == "bad";
}

test "copy of a narrowed Result passes where a Result is expected" {
	const got = copyPick(true);
	let seen = 0;
	if (got.ok) {
		const h = got;
		seen = copyWidth(h);
	}
	assert seen == 9;
}

test "copy of a narrowed Result returns as the Result, other payload types" {
	assert copyForward(Result.ok("hi")).ok;
	assert !copyForward(Result.err(7)).ok;
	assert copyText(Result.ok("hi")) == "hi";
	assert copyText(Result.err(7)) == "none";
}

enum CopyKind { A, B }

type CopyVariantData = match (kind: CopyKind) {
	CopyKind.A => {},
	CopyKind.B => { flag: boolean },
};

type CopyVariant = Ref<CopyVariantData>;
type CopyPlain = { ok: true; value: CopyVariant } | { ok: false; error: string };

function copyMake(): CopyPlain {
	const v: CopyVariant = { kind: CopyKind.B, flag: true };
	return { ok: true, value: v };
}

test "a nested discriminant test narrows through the narrowed union" {
	const r = copyMake();
	let seen = false;
	if (r.ok) {
		if (r.value.kind == CopyKind.B) seen = r.value.flag;
	}
	assert seen;
}

// --- a narrowed variant meets a parameter written as the same object type ---
import { okText, okCount } from "./fixtures/objectParameters";

type VariantPair = match (ok: boolean) {
	true => { value: string },
	false => { error: string },
};

function variantPair(good: boolean): VariantPair {
	if (good) return { ok: true, value: "lib" };
	return { ok: false, error: "nope" };
}

function variantCount(good: boolean): Result<int32, string> {
	if (good) return Result.ok(7);
	return Result.err("no");
}

function variantWide(x: { ok: boolean; value: string }): string {
	return `${x.ok}:${x.value}`;
}

function variantTaker(x: VariantPair): boolean {
	return x.ok;
}

test "a narrowed match variant passes to a parameter of the same object type" {
	const p = variantPair(true);
	let seen = "";
	if (p.ok) seen = okText(p);
	assert seen == "true:lib";
}

test "a narrowed Result passes to a parameter of the same object type" {
	const r = variantCount(true);
	let seen = 0;
	if (r.ok) seen = okCount(r);
	assert seen == 7;
}

test "a narrowed variant passes where the discriminant is written boolean" {
	const p = variantPair(true);
	let seen = "";
	if (p.ok) seen = variantWide(p);
	assert seen == "true:lib";
}

test "a narrowed variant is stored in a typed local and pushed into an array declared before the guard" {
	const p = variantPair(true);
	const r = variantCount(true);
	const texts: { ok: true; value: string }[] = [];
	const counts: { ok: true; value: int32 }[] = [];
	let seen = "";
	if (p.ok) {
		const q: { ok: true; value: string } = p;
		seen = q.value;
		texts.push(p);
	}
	if (r.ok) counts.push(r);
	assert seen == "lib";
	assert texts.length == 1 && texts[0].value == "lib";
	assert counts.length == 1 && counts[0].value == 7;
}

test "a value written as the variant's object type passes where the match type is expected" {
	const v: { ok: true; value: string } = { ok: true, value: "w" };
	assert variantTaker(v);
}
