// Language tests: MetaScript-specific syntax — ?., ??, move, sizeof, distinct, etc.
// Tests features unique to MetaScript that aren't covered elsewhere.

// =========================================================
// 1. Optional chaining (?.)
// =========================================================

interface Address {
	city: string;
	zip: string;
}

interface User {
	name: string;
	address: Address;
}

test "optional chaining basic" {
	const u: User = { name: "Alice", address: { city: "NYC", zip: "10001" } };
	const city = u?.name;
	assert city === "Alice";
}

// =========================================================
// 2. Nullish coalescing (??)
// =========================================================

test "nullish coalescing with values" {
	const a: number = 42;
	const b = a ?? 0;
	assert b === 42;
}

test "nullish coalescing with null" {
	const a = null as unknown as string;
	const b = a ?? "default";
	assert b === "default";
}

// =========================================================
// 3. Exponentiation operator
// =========================================================

test "exponentiation" {
	assert 2 ** 3 === 8;
	assert 3 ** 2 === 9;
	assert 2 ** 10 === 1024;
	assert 5 ** 0 === 1;
}

// =========================================================
// 4. Increment / Decrement
// =========================================================

test "increment and decrement" {
	let x = 5;
	x++;
	assert x === 6;
	x--;
	assert x === 5;
}

// =========================================================
// 5. Negative numbers and unary minus
// =========================================================

test "unary minus" {
	const a = -5;
	assert a === -5;
	assert -a === 5;
	assert -(-3) === 3;
}

// =========================================================
// 6. Nested ternary
// =========================================================

function classify(n: number): string {
	return n > 0 ? "positive" : n < 0 ? "negative" : "zero";
}

test "nested ternary" {
	assert classify(5) === "positive";
	assert classify(-3) === "negative";
	assert classify(0) === "zero";
}

// =========================================================
// 7. String + boolean coercion
// =========================================================

test "string + boolean coercion" {
	assert "val=" + true === "val=true";
	assert "val=" + false === "val=false";
}

// =========================================================
// 8. Multiple assignment
// =========================================================

test "multiple variable declarations" {
	let a = 1;
	let b = 2;
	let c = 3;
	const sum = a + b + c;
	assert sum === 6;

	// Swap via temp
	let temp = a;
	a = b;
	b = temp;
	assert a === 2;
	assert b === 1;
}

// =========================================================
// 9. Chained comparison via boolean
// =========================================================

function inRange(x: number, lo: number, hi: number): boolean {
	return x >= lo && x <= hi;
}

test "chained boolean logic" {
	assert inRange(5, 0, 10);
	assert inRange(0, 0, 10);
	assert inRange(10, 0, 10);
	assert !inRange(-1, 0, 10);
	assert !inRange(11, 0, 10);
}

// =========================================================
// 10. Complex expression nesting
// =========================================================

test "complex expressions" {
	assert (2 + 3) * 4 === 20;
	assert 2 + 3 * 4 === 14;
	assert (10 - 2) / (4 - 2) === 4;
	assert 1 + 2 + 3 + 4 + 5 === 15;
}

// =========================================================
// 11. Type alias for function types
// =========================================================

type Predicate = (n: number) => boolean;
type Transform = (s: string) => string;

function filter(arr: number[], pred: Predicate): number[] {
	const result: number[] = [];
	let i = 0;
	while (i < arr.length) {
		if (pred(arr[i])) result.push(arr[i]);
		i += 1;
	}
	return result;
}

function mapStr(arr: string[], fn: Transform): string[] {
	const result: string[] = [];
	let i = 0;
	while (i < arr.length) {
		result.push(fn(arr[i]));
		i += 1;
	}
	return result;
}

function isPositive(n: number): boolean { return n > 0; }

test "function type aliases" {
	const pos = filter([-2, -1, 0, 1, 2, 3], isPositive);
	assert pos.length === 3;
	assert pos[0] === 1;
	assert pos[2] === 3;
}

function addBang(s: string): string { return s + "!"; }

test "string transform type alias" {
	const result = mapStr(["hello", "world"], addBang);
	assert result.length === 2;
	assert result[0] === "hello!";
	assert result[1] === "world!";
}

// =========================================================
// 12. Empty array / interface literals
// =========================================================

test "empty literals" {
	const empty: number[] = [];
	assert empty.length === 0;

	const strs: string[] = [];
	strs.push("a");
	assert strs.length === 1;
}

// =========================================================
// 13. Array literal with values
// =========================================================

test "array literals" {
	const nums: number[] = [10, 20, 30];
	assert nums.length === 3;
	assert nums[0] === 10;
	assert nums[2] === 30;

	const strs: string[] = ["a", "b", "c"];
	assert strs.length === 3;
	assert strs[1] === "b";
}

// =========================================================
// 14. Deeply nested member access
// =========================================================

interface Inner { val: number; }
interface Middle { inner: Inner; }
interface Outer { middle: Middle; name: string; }

test "deeply nested access" {
	const obj: Outer = {
		middle: { inner: { val: 42 } },
		name: "test",
	};
	assert obj.middle.inner.val === 42;
	assert obj.name === "test";
}

// =========================================================
// 15. Short-circuit evaluation
// =========================================================

let scAndCalled = false;
function sideEffectAnd(): boolean { scAndCalled = true; return true; }

let scOrCalled = false;
function sideEffectOr(): boolean { scOrCalled = true; return false; }

test "short-circuit AND" {
	const r = false && sideEffectAnd();
	assert !scAndCalled;
	assert !r;
}

test "short-circuit OR" {
	const r = true || sideEffectOr();
	assert !scOrCalled;
	assert r;
}
