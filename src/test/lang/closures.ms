// Language tests: closures and arrow functions

// --- Shared type aliases ---

type NumFn = (n: number) => number;
type Predicate = (n: number) => boolean;

// --- Shared helper functions ---

const double = (x: number): number => x * 2;
const greet = (name: string): string => "hi " + name;
const isEven = (n: number): boolean => n % 2 == 0;

function add1(x: number): number { return x + 1; }

function makeAdder(base: number): NumFn {
	return (x: number): number => base + x;
}

function compose(f: NumFn, g: NumFn): NumFn {
	return (x: number): number => f(g(x));
}

function makeRange(lo: number, hi: number): Predicate {
	return (x: number): boolean => x >= lo && x <= hi;
}

function applyTwice(f: NumFn, x: number): number {
	return f(f(x));
}

function applyToEach(arr: number[], f: NumFn): number[] {
	const result: number[] = [];
	let i = 0;
	while (i < arr.length) {
		result.push(f(arr[i]));
		i += 1;
	}
	return result;
}

function makeCounter(): NumFn {
	let count = 0;
	return (inc: number): number => {
		count += inc;
		return count;
	};
}

function makeMultiplier(factor: number): NumFn {
	return (x: number): number => x * factor;
}

function countMatching(arr: number[], pred: Predicate): number {
	let count = 0;
	let i = 0;
	while (i < arr.length) {
		if (pred(arr[i])) count += 1;
		i += 1;
	}
	return count;
}

// --- Tests: arrow functions ---

test "arrow function double" {
	assert double(5) == 10;
}

test "arrow function greet" {
	assert greet("alice") == "hi alice";
}

test "arrow function isEven" {
	assert isEven(4);
	assert !isEven(3);
}

// --- Tests: basic closures ---

test "basic closures" {
	const add5 = makeAdder(5);
	const add10 = makeAdder(10);
	assert add5(3) == 8;
	assert add10(3) == 13;
	assert add5(0) == 5;
	assert add10(-10) == 0;
}

test "closure multiplier" {
	const triple = makeMultiplier(3);
	assert triple(7) == 21;
}

// --- Tests: multi-capture ---

test "multi-capture" {
	const inRange = makeRange(10, 20);
	assert inRange(15) == true;
	assert inRange(5) == false;
	assert inRange(25) == false;
}

// --- Tests: mutable capture ---

test "closure counter" {
	const counter = makeCounter();
	assert counter(1) == 1;
	assert counter(5) == 6;
	assert counter(0) == 6;
}

// --- Tests: nested closures ---

test "nested closures (compose)" {
	const doubleAdd1 = compose(double, add1);
	assert doubleAdd1(3) == 8;
	assert doubleAdd1(0) == 2;
}

// --- Tests: higher-order / callback patterns ---

test "applyTwice" {
	assert applyTwice(double, 3) == 12;
	assert applyTwice(add1, 5) == 7;
}

test "applyToEach" {
	const doubled = applyToEach([1, 2, 3], double);
	assert doubled.length == 3;
	assert doubled[0] == 2;
	assert doubled[1] == 4;
	assert doubled[2] == 6;
}

test "callback countMatching" {
	const nums: number[] = [1, 2, 3, 4, 5, 6, 7, 8];
	assert countMatching(nums, isEven) == 4;
	assert countMatching(nums, (n: number): boolean => n > 5) == 3;
}
