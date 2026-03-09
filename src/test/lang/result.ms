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
