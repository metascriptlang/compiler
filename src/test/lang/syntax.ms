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
	assert city == "Alice";
}

// =========================================================
// 2. Nullish coalescing (??)
// =========================================================

test "nullish coalescing with values" {
	const a: number = 42;
	const b = a ?? 0;
	assert b == 42;
}

test "nullish coalescing with null" {
	const a = null as unknown as string;
	const b = a ?? "default";
	assert b == "default";
}

type NullishDirection = "row" | "column";

function nullishWidened(v: uint8 | null): uint32 {
	const x: uint32 = v ?? 1;
	return x;
}

function nullishCrossesInt64(v: int32 | null, d: int64): int64 {
	const fromLiteral: int64 = v ?? 0;
	const fromValue: int64 = v ?? d;
	return fromLiteral + fromValue;
}

function nullishDirection(s: NullishDirection | null): NullishDirection {
	const d: NullishDirection = s ?? "row";
	return d;
}

function nullishJoinKind(t: string | null): string {
	const r = t ?? 1;
	return typeof r;
}

test "nullish coalescing fits its payload and its fallback into the slot like a conditional" {
	assert nullishWidened(7) == 7;
	assert nullishWidened(null) == 1;
	assert nullishCrossesInt64(7, 5 as int64) == 14;
	assert nullishCrossesInt64(null, 5 as int64) == 5;
	assert nullishDirection("column") == "column";
	assert nullishDirection(null) == "row";
}

test "nullish coalescing without a slot joins its payload and its fallback" {
	assert nullishJoinKind("s") == "string";
	assert nullishJoinKind(null) == "number";
}

class NullishHolder { v: int32 | null = 4; }

let nullishCalls = 0;

function nullishCounted(): uint8 | null {
	nullishCalls += 1;
	return 7;
}

function nullishHolder(): NullishHolder {
	nullishCalls += 1;
	return new NullishHolder();
}

test "nullish coalescing evaluates its left operand once" {
	nullishCalls = 0;
	const x: uint32 = nullishCounted() ?? 1;
	assert x == 7;
	assert nullishCalls == 1;
	const slots: (int32 | null)[] = [null, 5, null];
	let i = 0;
	const first = slots[i++] ?? 9;
	const second = slots[i++] ?? 9;
	assert first == 9;
	assert second == 5;
	assert i == 2;
	nullishCalls = 0;
	const v = nullishHolder().v ?? 0;
	assert v == 4;
	assert nullishCalls == 1;
}

class NullishLeaf { v: int32; constructor(v: int32) { this.v = v; } }
struct NullishSlot { o: int32 | null; leaf: NullishLeaf | null; }
function nullishThroughRef(ref slot: NullishSlot): int32 { return slot.o ?? -1; }
function nullishThroughOut(out slot: NullishSlot): int32 { slot = { o: 6, leaf: null }; return slot.o ?? -1; }
function nullishLeafThroughRef(ref slot: NullishSlot): int32 { return (slot.leaf ?? new NullishLeaf(-1)).v; }
function nullishBump(ref slot: NullishSlot): void { if (slot.o != null) slot.o = slot.o + 1; }

test "nullish coalescing and optional chaining read a field through a ref, out or boxed binding" {
	let slot: NullishSlot = { o: 4, leaf: new NullishLeaf(9) };
	assert nullishThroughRef(slot) == 4;
	assert nullishLeafThroughRef(slot) == 9;
	let fresh: NullishSlot = { o: null, leaf: null };
	assert nullishThroughOut(fresh) == 6;
	nullishBump(slot);
	assert (slot.o ?? -1) == 5;
	assert (slot.leaf?.v ?? -1) == 9;
	let empty: NullishSlot = { o: null, leaf: null };
	nullishBump(empty);
	assert (empty.o ?? -1) == -1;
	assert nullishLeafThroughRef(empty) == -1;
}

// =========================================================
// 3. Exponentiation operator
// =========================================================

test "exponentiation" {
	assert 2 ** 3 == 8;
	assert 3 ** 2 == 9;
	assert 2 ** 10 == 1024;
	assert 5 ** 0 == 1;
}

// =========================================================
// 4. Increment / Decrement
// =========================================================

test "increment and decrement" {
	let x = 5;
	x++;
	assert x == 6;
	x--;
	assert x == 5;
}

// =========================================================
// 5. Negative numbers and unary minus
// =========================================================

test "unary minus" {
	const a = -5;
	assert a == -5;
	assert -a == 5;
	assert -(-3) == 3;
}

// =========================================================
// 6. Nested ternary
// =========================================================

function classify(n: number): string {
	return n > 0 ? "positive" : n < 0 ? "negative" : "zero";
}

test "nested ternary" {
	assert classify(5) == "positive";
	assert classify(-3) == "negative";
	assert classify(0) == "zero";
}

// =========================================================
// 7. String + boolean coercion
// =========================================================

test "string + boolean coercion" {
	assert "val=" + true == "val=true";
	assert "val=" + false == "val=false";
}

// =========================================================
// 8. Multiple assignment
// =========================================================

test "multiple variable declarations" {
	let a = 1;
	let b = 2;
	let c = 3;
	const sum = a + b + c;
	assert sum == 6;

	// Swap via temp
	let temp = a;
	a = b;
	b = temp;
	assert a == 2;
	assert b == 1;
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
	assert (2 + 3) * 4 == 20;
	assert 2 + 3 * 4 == 14;
	assert (10 - 2) / (4 - 2) == 4;
	assert 1 + 2 + 3 + 4 + 5 == 15;
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
	assert pos.length == 3;
	assert pos[0] == 1;
	assert pos[2] == 3;
}

function addBang(s: string): string { return s + "!"; }

test "string transform type alias" {
	const result = mapStr(["hello", "world"], addBang);
	assert result.length == 2;
	assert result[0] == "hello!";
	assert result[1] == "world!";
}

// =========================================================
// 12. Empty array / interface literals
// =========================================================

test "empty literals" {
	const empty: number[] = [];
	assert empty.length == 0;

	const strs: string[] = [];
	strs.push("a");
	assert strs.length == 1;
}

// =========================================================
// 13. Array literal with values
// =========================================================

test "array literals" {
	const nums: number[] = [10, 20, 30];
	assert nums.length == 3;
	assert nums[0] == 10;
	assert nums[2] == 30;

	const strs: string[] = ["a", "b", "c"];
	assert strs.length == 3;
	assert strs[1] == "b";
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
	assert obj.middle.inner.val == 42;
	assert obj.name == "test";
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
