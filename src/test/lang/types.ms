// Language tests: type system — sized ints, .code, enums, bitwise, type aliases

// ===== Shared definitions =====

enum Color {
	Red,
	Green,
	Blue,
}

function colorName(c: Color): string {
	return match (c) {
		Color.Red => "red",
		Color.Green => "green",
		Color.Blue => "blue",
		_ => "unknown",
	};
}

interface Point {
	x: number;
	y: number;
}

function makePoint(x: number, y: number): Point {
	return { x, y };
}

function distSq(p: Point): number {
	return p.x * p.x + p.y * p.y;
}

interface Rect {
	origin: Point;
	width: number;
	height: number;
}

function area(r: Rect): number {
	return r.width * r.height;
}

interface NumberPair {
	first: number;
	second: number;
}

function sumPair(p: NumberPair): number {
	return p.first + p.second;
}

function makePair(a: number, b: number): NumberPair {
	return { first: a, second: b };
}

function isDigit(ch: number): boolean {
	return ch >= "0".code && ch <= "9".code;
}

function isUpper(ch: number): boolean {
	return ch >= "A".code && ch <= "Z".code;
}

function direction(d: number): string {
	if (d === 0) return "north";
	if (d === 1) return "south";
	if (d === 2) return "east";
	if (d === 3) return "west";
	unreachable;
}

function isPowerOf2(n: int32): boolean {
	if (n <= 0) return false;
	return (n & (n - 1)) === 0;
}

// ===== Sized integers =====

test "int32 arithmetic" {
	const a: int32 = 42;
	const b: int32 = 8;
	assert a + b === 50;
	assert a * b === 336;
}

test "int64 arithmetic" {
	const a: int64 = 1000000;
	const b: int64 = 2000000;
	assert a + b === 3000000;
}

test "uint32 range" {
	const u: uint32 = 4294967295;
	assert u > 0;
}

test "float32 and float64" {
	const f32: float32 = 3.14;
	assert f32 > 3.0;
	assert f32 < 4.0;

	const f64: float64 = 2.718281828;
	assert f64 > 2.7;
}

// ===== Enums =====

test "enum ordinal values" {
	assert Color.Red === 0;
	assert Color.Green === 1;
	assert Color.Blue === 2;
}

test "enum match dispatch" {
	assert colorName(Color.Red) === "red";
	assert colorName(Color.Blue) === "blue";
}

// ===== Interfaces =====

test "interface construction and field access" {
	const p = makePoint(3.0, 4.0);
	assert p.x === 3.0;
	assert p.y === 4.0;
	assert distSq(p) === 25.0;
}

test "nested interfaces" {
	const r: Rect = { origin: makePoint(0.0, 0.0), width: 5.0, height: 3.0 };
	assert area(r) === 15.0;
}

// ===== Type aliases =====

test "type alias for interface" {
	const pair = makePair(10, 20);
	assert sumPair(pair) === 30;
}

// ===== Char .code =====

test "char code literals" {
	assert "A".code === 65;
	assert "a".code === 97;
	assert "0".code === 48;
	assert "\n".code === 10;
}

test "char classification with .code" {
	assert isDigit("5".code);
	assert !isDigit("x".code);
	assert isUpper("Z".code);
	assert !isUpper("z".code);
}

// ===== Unreachable =====

test "unreachable as exhaustiveness marker" {
	assert direction(0) === "north";
	assert direction(3) === "west";
}

// ===== Bitwise operators =====

test "bitwise AND" {
	const a: int32 = 0xFF;
	const b: int32 = 0x0F;
	assert (a & b) === 0x0F;

	const c: int32 = 0b1100;
	const d: int32 = 0b1010;
	assert (c & d) === 0b1000;

	const e: int32 = 7;
	const f: int32 = 3;
	assert (e & f) === 3;
}

test "bitwise OR" {
	const a: int32 = 0xF0;
	const b: int32 = 0x0F;
	assert (a | b) === 0xFF;

	const c: int32 = 4;
	const d: int32 = 2;
	assert (c | d) === 6;
}

test "bitwise XOR" {
	const a: int32 = 0xFF;
	assert (a ^ a) === 0;
	const b: int32 = 0x00;
	assert (a ^ b) === 0xFF;

	const c: int32 = 5;
	const d: int32 = 3;
	assert (c ^ d) === 6;
}

test "bitwise NOT" {
	const a: int32 = 0;
	assert ~a === -1;

	const b: int32 = -1;
	assert ~b === 0;
}

test "left shift" {
	const one: int32 = 1;
	assert (one << 0) === 1;
	assert (one << 1) === 2;
	assert (one << 3) === 8;

	const three: int32 = 3;
	assert (three << 2) === 12;
}

test "right shift" {
	const a: int32 = 8;
	assert (a >> 1) === 4;

	const b: int32 = 16;
	assert (b >> 2) === 4;

	const c: int32 = 255;
	assert (c >> 4) === 15;
}

// ===== Hex and binary literals =====

test "hex and binary literals" {
	const a: int32 = 0xFF;
	const b: int32 = 0x10;
	const c: int32 = 0b1111;
	const d: int32 = 0b10000000;
	assert a === 255;
	assert b === 16;
	assert c === 15;
	assert d === 128;
}

// ===== Compound assignment =====

test "compound assignment operators" {
	let x: number = 10;
	x += 5;
	assert x === 15;
	x -= 3;
	assert x === 12;
	x *= 2;
	assert x === 24;
	x /= 4;
	assert x === 6;

	let y: int32 = 10;
	y %= 4;
	assert y === 2;
}

// ===== Bit flag pattern =====

test "bit flag pattern" {
	const FLAG_READ: int32 = 1;
	const FLAG_WRITE: int32 = 2;
	const FLAG_EXEC: int32 = 4;

	let perms: int32 = 0;
	perms = perms | FLAG_READ;
	perms = perms | FLAG_WRITE;
	assert (perms & FLAG_READ) !== 0;
	assert (perms & FLAG_WRITE) !== 0;
	assert (perms & FLAG_EXEC) === 0;

	perms = perms | FLAG_EXEC;
	assert (perms & FLAG_EXEC) !== 0;

	perms = perms & (~FLAG_WRITE);
	assert (perms & FLAG_WRITE) === 0;
	assert (perms & FLAG_READ) !== 0;
}

// ===== Power of 2 check =====

test "power of 2 via bitwise trick" {
	const p1: int32 = 1;
	const p2: int32 = 2;
	const p4: int32 = 4;
	const p64: int32 = 64;
	const p3: int32 = 3;
	const p6: int32 = 6;
	const p0: int32 = 0;
	assert isPowerOf2(p1);
	assert isPowerOf2(p2);
	assert isPowerOf2(p4);
	assert isPowerOf2(p64);
	assert !isPowerOf2(p3);
	assert !isPowerOf2(p6);
	assert !isPowerOf2(p0);
}

// ===== Intersection types (erasure tier) =====
//
// Intersection types `T & U` are accepted by the parser and erase at the
// resolver to their left-most operand. Branded type pattern (`string & { __brand }`)
// compiles as `string` at runtime. Object intersection is parsed but only the
// first operand's fields are visible (full TS-compat field merge is a follow-up).

test "branded primitive ID compiles and runs" {
	type CubeId = string & { __brand: "CubeId" };
	const id: CubeId = "abc-123" as CubeId;
	assert id === "abc-123";
}

test "intersection inline annotation" {
	const x: string & { __brand: "X" } = "hello";
	assert x === "hello";
}

test "multi-operand intersection chain" {
	type Triple = string & { a: number } & { b: number };
	const v: Triple = "x" as Triple;
	assert v === "x";
}

test "intersection mixed with union — A | B & C parses precedence-aware" {
	// Erasure: parses as number | (string & {...}). Both numeric and string
	// values remain assignable through the union; the intersection arm
	// erases to its first operand (string).
	type Mixed = number | string & { tag: "branded" };
	const a: Mixed = 42;
	assert a === 42;
}
