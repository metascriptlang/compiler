// Language tests: advanced closures — nested, mutable capture, pipelines

// --- Shared type aliases ---

type NumFn = (n: number) => number;
type StrFn = (s: string) => string;
type BoolFn = (n: number) => boolean;
type FnFactory = (n: number) => NumFn;

// --- Shared interfaces ---

interface CounterPair {
	inc: NumFn;
	read: NumFn;
}

interface Transform {
	name: string;
	apply: NumFn;
}

// --- Shared helper functions ---

function add1(x: number): number { return x + 1; }
function mul2(x: number): number { return x * 2; }
function square(x: number): number { return x * x; }
function cube(x: number): number { return x * x * x; }

function makeAdder(base: number): NumFn {
	return (x: number): number => base + x;
}

function makeGreeter(greeting: string): StrFn {
	return (name: string): string => greeting + " " + name;
}

function makeScaler(factor: number): NumFn {
	return (x: number): number => x * factor;
}

function compose(f: NumFn, g: NumFn): NumFn {
	return (x: number): number => f(g(x));
}

function makeOp(op: string): FnFactory {
	if (op == "add") {
		return (base: number): NumFn => {
			return (x: number): number => base + x;
		};
	}
	return (base: number): NumFn => {
		return (x: number): number => base * x;
	};
}

function makeFormatter(prefix: string, width: number): (dummy: number) => string {
	return (dummy: number): string => {
		let result = prefix;
		let i = prefix.length;
		while (i < width) {
			result = result + ".";
			i += 1;
		}
		return result;
	};
}

function makeCounterPair(): CounterPair {
	let count = 0;
	const incFn = (n: number): number => {
		count += n;
		return count;
	};
	const getFn = (dummy: number): number => count;
	return { inc: incFn, read: getFn };
}

function makeRangeCheck(lo: number, hi: number): BoolFn {
	return (n: number): boolean => n >= lo && n <= hi;
}

function makeModCheck(divisor: number): BoolFn {
	return (n: number): boolean => n % divisor == 0;
}

function countWhere(arr: number[], pred: BoolFn): number {
	let count = 0;
	let i = 0;
	while (i < arr.length) {
		if (pred(arr[i])) count += 1;
		i += 1;
	}
	return count;
}

function filterNums(arr: number[], pred: BoolFn): number[] {
	const result: number[] = [];
	let i = 0;
	while (i < arr.length) {
		if (pred(arr[i])) result.push(arr[i]);
		i += 1;
	}
	return result;
}

function applyAll(arr: number[], fn: NumFn): number[] {
	const result: number[] = [];
	let i = 0;
	while (i < arr.length) {
		result.push(fn(arr[i]));
		i += 1;
	}
	return result;
}

function applyPipeline(transforms: NumFn[], initial: number): number {
	let value = initial;
	let i = 0;
	while (i < transforms.length) {
		value = transforms[i](value);
		i += 1;
	}
	return value;
}

function reduceSum(arr: number[]): number {
	let acc = 0;
	let i = 0;
	while (i < arr.length) {
		acc = acc + arr[i];
		i += 1;
	}
	return acc;
}

function reduceProduct(arr: number[]): number {
	let acc = 1;
	let i = 0;
	while (i < arr.length) {
		acc = acc * arr[i];
		i += 1;
	}
	return acc;
}

function makeMultipliers(factors: number[]): NumFn[] {
	const fns: NumFn[] = [];
	for (const f of factors) {
		fns.push((x: number): number => x * f);
	}
	return fns;
}

function makeTransform(name: string, offset: number): Transform {
	const fn = (x: number): number => x + offset;
	return { name: name, apply: fn };
}

function makeValidator(requirePositive: boolean, maxVal: number): BoolFn {
	return (n: number): boolean => {
		if (requirePositive && n < 0) return false;
		if (n > maxVal) return false;
		return true;
	};
}

function computeWithHelper(x: number): number {
	const helper = (n: number): number => n * n + 1;
	return helper(x) + helper(x + 1);
}

// =========================================================
// Tests
// =========================================================

test "basic closure — capture immutable param" {
	const add3 = makeAdder(3);
	const add100 = makeAdder(100);
	assert add3(7) == 10;
	assert add100(1) == 101;
	assert add3(0) == 3;
}

test "string capture closure" {
	const hello = makeGreeter("hello");
	const hi = makeGreeter("hi");
	assert hello("world") == "hello world";
	assert hi("there") == "hi there";
	assert hello("alice") == "hello alice";
}

test "closure returning closure (nested factory)" {
	const addFactory = makeOp("add");
	const mulFactory = makeOp("mul");
	const add5 = addFactory(5);
	const mul3 = mulFactory(3);
	assert add5(10) == 15;
	assert mul3(4) == 12;
	assert add5(0) == 5;
}

test "multi-type capture (string + number)" {
	const fmt1 = makeFormatter("abc", 6);
	assert fmt1(0) == "abc...";

	const fmt2 = makeFormatter("x", 4);
	assert fmt2(0) == "x...";

	const fmt3 = makeFormatter("hello", 5);
	assert fmt3(0) == "hello";
}

test "mutable counter — shared env" {
	const cp = makeCounterPair();
	assert cp.read(0) == 0;
	assert cp.inc(5) == 5;
	assert cp.inc(3) == 8;
	assert cp.read(0) == 8;
	assert cp.inc(2) == 10;
}

test "compose chain" {
	const mul2ThenAdd1 = compose(add1, mul2);
	assert mul2ThenAdd1(5) == 11;

	const add1ThenMul2 = compose(mul2, add1);
	assert add1ThenMul2(3) == 8;
	assert add1ThenMul2(5) == 12;

	const doubleThenSquare = compose(square, mul2);
	assert doubleThenSquare(3) == 36;

	const triple = compose(add1, compose(mul2, add1));
	assert triple(4) == 11;
}

test "predicate closures — range and mod" {
	const nums: number[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
	const inRange = makeRangeCheck(3, 7);
	const isEven = makeModCheck(2);
	const divBy3 = makeModCheck(3);

	assert countWhere(nums, inRange) == 5;
	assert countWhere(nums, isEven) == 5;
	assert countWhere(nums, divBy3) == 3;

	assert inRange(5);
	assert inRange(3);
	assert !inRange(2);
	assert !inRange(8);
}

test "filter with closures" {
	const inRange = makeRangeCheck(10, 20);
	const isEven = makeModCheck(2);

	const evens = filterNums([1, 2, 3, 4, 5, 6], isEven);
	assert evens.length == 3;
	assert evens[0] == 2;

	const inBounds = filterNums([5, 10, 15, 20, 25], inRange);
	assert inBounds.length == 3;
	assert inBounds[0] == 10;
	assert inBounds[2] == 20;
}

test "closure as callback — map pattern" {
	const addTen = makeAdder(10);
	const mapped = applyAll([1, 2, 3], addTen);
	assert mapped.length == 3;
	assert mapped[0] == 11;
	assert mapped[1] == 12;
	assert mapped[2] == 13;
}

test "factory pattern — scaler" {
	const times3 = makeScaler(3);
	const times5 = makeScaler(5);
	assert times3(4) == 12;
	assert times5(4) == 20;
	assert times3(times5(2)) == 30;
}

test "loop closures — for..of capture" {
	const muls = makeMultipliers([2, 3, 5]);
	assert muls.length == 3;
	assert muls[0](10) == 20;
	assert muls[1](10) == 30;
	assert muls[2](10) == 50;
}

test "closure in interface field" {
	const t1 = makeTransform("plus10", 10);
	const t2 = makeTransform("plus20", 20);

	assert t1.name == "plus10";
	assert t1.apply(5) == 15;
	assert t2.apply(5) == 25;
}

test "transform pipeline" {
	const pipeline: NumFn[] = [];
	pipeline.push((x: number): number => x + 10);
	pipeline.push((x: number): number => x * 2);
	pipeline.push((x: number): number => x - 5);

	assert applyPipeline(pipeline, 3) == 21;
	assert applyPipeline(pipeline, 0) == 15;
}

test "immediate closure invocation" {
	assert computeWithHelper(3) == 27;
	assert computeWithHelper(0) == 3;
}

test "boolean capture — validator" {
	const strictVal = makeValidator(true, 100);
	const laxVal = makeValidator(false, 1000);

	assert strictVal(50);
	assert !strictVal(-1);
	assert !strictVal(200);
	assert laxVal(-5);
	assert laxVal(500);
	assert !laxVal(2000);
}

test "manual reduce" {
	assert reduceSum([1, 2, 3, 4]) == 10;
	assert reduceProduct([1, 2, 3, 4]) == 24;
	assert reduceSum([]) == 0;
}

test "top-level helper composition" {
	assert square(2) + cube(2) == 12;
	assert square(3) + cube(3) == 36;
}
