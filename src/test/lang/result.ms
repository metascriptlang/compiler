// Language tests: Result<T,E> + try operator

type DivResult = Result<number, string>;

function divide(a: number, b: number): DivResult {
	if (b === 0) return Result.err("division by zero");
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
	assert r.ok === true;
	assert r.value === 5;
}

test "basic Result err" {
	const r = divide(10, 0);
	assert r.ok === false;
	assert r.error === "division by zero";
}

test "try operator ok" {
	const r = halfDivide(20, 4);
	assert r.ok === true;
	assert r.value === 2.5;
}

test "try operator err propagation" {
	const r = halfDivide(10, 0);
	assert r.ok === false;
	assert r.error === "division by zero";
}

test "try catch fallback" {
	assert safeDivide(10, 2) === 5;
	assert safeDivide(10, 0) === 0;
}

test "Result chain ok" {
	const r = chain(100, 2, 5);
	assert r.ok === true;
	assert r.value === 10;
}

test "Result chain first err" {
	const r = chain(100, 0, 5);
	assert r.ok === false;
}

test "Result chain second err" {
	const r = chain(100, 2, 0);
	assert r.ok === false;
}

test "manual Result check" {
	const r = divide(42, 7);
	if (r.ok) {
		assert r.value === 6;
	}
}

// try inside Result<void, E> — error path must propagate as Result<void, E>, not Result<T, E>
function doWork(): Result<number, string> {
	return Result.ok(42);
}

function process(): Result<void, string> {
	const val = try doWork();
	console.log("got value");
	return Result.ok();
}

test "try inside Result void fn ok" {
	const r = process();
	assert r.ok === true;
}

function failWork(): Result<number, string> {
	return Result.err("oops");
}

function failProcess(): Result<void, string> {
	const val = try failWork();
	return Result.ok();
}

test "try inside Result void fn err propagation" {
	const r = failProcess();
	assert r.ok === false;
	assert r.error === "oops";
}

// Nested: outer Result<void, E>, inner Result<number, E>
function innerCalc(): Result<number, string> {
	const x = try doWork();
	return Result.ok(x + 1);
}

function outerVoid(): Result<void, string> {
	const n = try innerCalc();
	console.log("nested ok");
	return Result.ok();
}

test "try nested functions different Result types" {
	const r = outerVoid();
	assert r.ok === true;
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
	assert a.ok && b.ok === false;
	if (a.ok) assert a.value === 7;
	if (!b.ok) assert b.error === 9;
}

// --- Nested Result<Result<T, E1>, E2> ---
function nested(x: number): Result<Result<number, string>, string> {
	if (x < 0) return Result.err("outer fail");
	if (x === 0) return Result.ok(Result.err("inner fail"));
	return Result.ok(Result.ok(x));
}

test "Nested Result — outer ok, inner ok" {
	const r = nested(5);
	assert r.ok;
	if (r.ok) {
		const inner = r.value;
		assert inner.ok;
		if (inner.ok) assert inner.value === 5;
	}
}

test "Nested Result — outer ok, inner err" {
	const r = nested(0);
	assert r.ok;
	if (r.ok) {
		const inner = r.value;
		assert !inner.ok;
		if (!inner.ok) assert inner.error === "inner fail";
	}
}

test "Nested Result — outer err" {
	const r = nested(-1);
	assert !r.ok;
	if (!r.ok) assert r.error === "outer fail";
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
		assert r.value.name === "Alice";
		assert r.value.age === 30;
	}
}

test "Result<Ref<Struct>, string> — err variant" {
	const r = makePerson("Bob", -1);
	assert !r.ok;
	if (!r.ok) assert r.error === "invalid age";
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
		assert r.value.length === 3;
		assert r.value[0] === 0;
		assert r.value[2] === 2;
	}
}

test "Result<number[], string> — ok with empty array" {
	const r = makeRange(0);
	assert r.ok;
	if (r.ok) assert r.value.length === 0;
}

test "Result<number[], string> — err variant" {
	const r = makeRange(-5);
	assert !r.ok;
	if (!r.ok) assert r.error === "negative count";
}

// --- Result with string payload — ensure RC managed correctly ---
function buildMessage(name: string, ok: boolean): Result<string, string> {
	if (ok) return Result.ok("hello, " + name);
	return Result.err("rejected: " + name);
}

test "Result<string, string> — ok with concatenated payload" {
	const r = buildMessage("world", true);
	assert r.ok;
	if (r.ok) assert r.value === "hello, world";
}

test "Result<string, string> — multiple instances in same scope (DRC stress)" {
	const a = buildMessage("a", true);
	const b = buildMessage("b", false);
	const c = buildMessage("c", true);
	if (a.ok) assert a.value === "hello, a";
	if (!b.ok) assert b.error === "rejected: b";
	if (c.ok) assert c.value === "hello, c";
}

// --- Result + try chain that traverses through 3 functions ---
function step1(x: number): Result<number, string> {
	if (x === 0) return Result.err("step1 fail");
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
	if (r.ok) assert r.value === 49;
}

test "try chain — fail at step1 propagates through all" {
	const r = step3(0);
	assert !r.ok;
	if (!r.ok) assert r.error === "step1 fail";
}

test "try chain — fail at step2 propagates" {
	const r = step3(60);  // step1: 120 → step2 overflow
	assert !r.ok;
	if (!r.ok) assert r.error === "step2 overflow";
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
	if (r.ok) assert r.value === 6;
	if (e.ok) assert e.value === 3;
}

// --- Result.ok() with no arg (Result<void, E>) construction ---
test "Result.ok() void construction" {
	const r: Result<void, string> = Result.ok();
	assert r.ok;
}

test "Result.err for Result<void, E>" {
	const r: Result<void, string> = Result.err("boom");
	assert !r.ok;
	if (!r.ok) assert r.error === "boom";
}
