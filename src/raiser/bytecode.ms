// Raiser VM — Bytecode format
// 32-bit instructions, Lua-style ABC/ABx/Ax encoding.
// Opcodes grow incrementally: i64 first, then i32/f32/f64.

import { test, check, testGroup } from "std/testing";

// --- Opcodes ---
// Start with i64 + control. Add typed variants as layers.

export enum RaiserOpcode {
	// Memory (3)
	LoadConst,        // ABx: R[A] = constants[Bx]
	Move,             // ABC: R[A] = R[B]
	LoadNil,          // ABC: R[A] = nil

	// i64 Arithmetic (6)
	AddI64,           // ABC: R[A] = R[B] + R[C]
	SubI64,           // ABC: R[A] = R[B] - R[C]
	MulI64,           // ABC: R[A] = R[B] * R[C]
	DivI64,           // ABC: R[A] = R[B] / R[C]
	ModI64,           // ABC: R[A] = R[B] % R[C]
	NegI64,           // ABC: R[A] = -R[B]

	// i64 Compare-Branch (6)
	BeqI64,           // ABC: if R[A] == R[B] skip C instructions
	BneI64,           // ABC: if R[A] != R[B] skip C instructions
	BltI64,           // ABC: if R[A] <  R[B] skip C instructions
	BleI64,           // ABC: if R[A] <= R[B] skip C instructions
	BgtI64,           // ABC: if R[A] >  R[B] skip C instructions
	BgeI64,           // ABC: if R[A] >= R[B] skip C instructions

	// Control (5)
	Jump,             // Ax:  pc += signedAx
	Call,             // ABC: R[A] = call func[B](R[A+1]..R[A+C])
	Ret,              // ABC: return R[A]
	Halt,             // ABC: stop, exit value = R[A]
	Print,            // ABC: debug print R[A]

	// Array operations (5)
	NewArray,         // ABC: R[A] = new array from R[A+1..A+B]
	LoadIndex,        // ABC: R[A] = R[B][R[C]]
	StoreIndex,       // ABC: R[A][R[B]] = R[C]
	ArrayLen,         // ABC: R[A] = len(R[B])
	ArrayPush,        // ABC: R[A].push(R[B])

	// Object operations (3)
	NewObject,        // ABC: R[A] = new empty object
	LoadField,        // ABC: R[A] = R[B].field(constants[C].strVal)
	StoreField,       // ABC: R[A].field(constants[B].strVal) = R[C]

	// String operations (6)
	ConcatStr,        // ABC: R[A] = toString(R[B]) + toString(R[C])
	EqStr,            // ABC: if R[A].strVal == R[B].strVal skip C
	NeStr,            // ABC: if R[A].strVal != R[B].strVal skip C
	StrLen,           // ABC: R[A] = R[B].strVal.length
	StrCharAt,        // ABC: R[A] = R[B].strVal[R[C].intVal] (single char)
	StrSlice,         // ABC: R[A] = R[B].strVal.slice(R[C].intVal, R[C+1].intVal)

	// Indirect call (1)
	CallIndirect,     // ABC: R[A] = call func[R[B].intVal](R[A+1]..R[A+C])
}

// --- Instruction ---
// Flat interface — no bit packing needed until .msb serialization (Layer 5+).
// Fields a/b/c are 0-255 (u8 range).

export interface RaiserInstruction {
	op: RaiserOpcode;
	a: number;
	b: number;
	c: number;
}

// --- Constructors ---

export function raiserABC(op: RaiserOpcode, a: number, b: number, c: number): RaiserInstruction {
	return { op, a, b, c };
}

export function raiserABx(op: RaiserOpcode, a: number, bx: number): RaiserInstruction {
	const bHigh = (bx / 256) | 0;
	const bLow = bx - bHigh * 256;
	return { op, a, b: bHigh, c: bLow };
}

export function raiserAx(op: RaiserOpcode, ax: number): RaiserInstruction {
	// 24-bit signed → split into a(high8), b(mid8), c(low8)
	// For negative values, add 2^24 to get unsigned representation
	let raw = ax;
	if (raw < 0) { raw = raw + 16777216; }
	const aHigh = (raw / 65536) | 0;
	const rem = raw - aHigh * 65536;
	const bMid = (rem / 256) | 0;
	const cLow = rem - bMid * 256;
	return { op, a: aHigh, b: bMid, c: cLow };
}

// --- Decoders ---

export function getBx(inst: RaiserInstruction): number {
	return inst.b * 256 + inst.c;
}

export function getSignedBx(inst: RaiserInstruction): number {
	const raw = inst.b * 256 + inst.c;
	if (raw >= 32768) return raw - 65536;
	return raw;
}

export function getSignedAx(inst: RaiserInstruction): number {
	const raw = inst.a * 65536 + inst.b * 256 + inst.c;
	if (raw >= 8388608) return raw - 16777216;
	return raw;
}

// --- Tests ---

testGroup("RaiserInstruction encoding", () => {
	test("ABC round-trip", () => {
		const inst = raiserABC(RaiserOpcode.AddI64, 2, 0, 1);
		check(inst.op === RaiserOpcode.AddI64);
		check(inst.a === 2);
		check(inst.b === 0);
		check(inst.c === 1);
	});

	test("ABx round-trip small", () => {
		const inst = raiserABx(RaiserOpcode.LoadConst, 3, 42);
		check(inst.op === RaiserOpcode.LoadConst);
		check(inst.a === 3);
		check(getBx(inst) === 42);
	});

	test("ABx round-trip large", () => {
		const inst = raiserABx(RaiserOpcode.LoadConst, 0, 1000);
		check(getBx(inst) === 1000);
	});

	test("ABx max value", () => {
		const inst = raiserABx(RaiserOpcode.LoadConst, 0, 65535);
		check(getBx(inst) === 65535);
	});

	test("Ax positive jump", () => {
		const inst = raiserAx(RaiserOpcode.Jump, 10);
		check(inst.op === RaiserOpcode.Jump);
		check(getSignedAx(inst) === 10);
	});

	test("Ax negative jump", () => {
		const inst = raiserAx(RaiserOpcode.Jump, -5);
		check(getSignedAx(inst) === -5);
	});

	test("Ax zero", () => {
		const inst = raiserAx(RaiserOpcode.Jump, 0);
		check(getSignedAx(inst) === 0);
	});

	test("signed Bx negative", () => {
		const inst = raiserABx(RaiserOpcode.LoadConst, 0, 65535);
		check(getSignedBx(inst) === -1);
	});

	test("signed Bx positive", () => {
		const inst = raiserABx(RaiserOpcode.LoadConst, 0, 100);
		check(getSignedBx(inst) === 100);
	});
});

testGroup("RaiserOpcode enum values", () => {
	test("first opcode is LoadConst", () => {
		const inst = raiserABC(RaiserOpcode.LoadConst, 0, 0, 0);
		check(inst.op === RaiserOpcode.LoadConst);
	});

	test("opcodes are distinct", () => {
		check(RaiserOpcode.AddI64 !== RaiserOpcode.SubI64);
		check(RaiserOpcode.Jump !== RaiserOpcode.Call);
		check(RaiserOpcode.Halt !== RaiserOpcode.Ret);
	});
});
