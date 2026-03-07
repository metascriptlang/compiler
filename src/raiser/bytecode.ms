// Raiser VM — Bytecode format
// 32-bit instructions, Lua-style ABC/ABx/Ax encoding.
// Opcodes grow incrementally: i64 first, then i32/f32/f64.


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

	// f64 Arithmetic (5)
	AddF64,           // ABC: R[A] = R[B].floatVal + R[C].floatVal
	SubF64,           // ABC: R[A] = R[B].floatVal - R[C].floatVal
	MulF64,           // ABC: R[A] = R[B].floatVal * R[C].floatVal
	DivF64,           // ABC: R[A] = R[B].floatVal / R[C].floatVal
	NegF64,           // ABC: R[A] = -R[B].floatVal

	// f64 Compare-Branch (6)
	BeqF64,           // ABC: if R[A].floatVal == R[B].floatVal skip C
	BneF64,           // ABC: if R[A].floatVal != R[B].floatVal skip C
	BltF64,           // ABC: if R[A].floatVal <  R[B].floatVal skip C
	BleF64,           // ABC: if R[A].floatVal <= R[B].floatVal skip C
	BgtF64,           // ABC: if R[A].floatVal >  R[B].floatVal skip C
	BgeF64,           // ABC: if R[A].floatVal >= R[B].floatVal skip C

	// Bitwise operations (6)
	BitAnd,           // ABC: R[A] = R[B] & R[C]
	BitOr,            // ABC: R[A] = R[B] | R[C]
	BitXor,           // ABC: R[A] = R[B] ^ R[C]
	BitNot,           // ABC: R[A] = ~R[B]
	ShiftLeft,        // ABC: R[A] = R[B] << R[C]
	ShiftRight,       // ABC: R[A] = R[B] >> R[C]

	// Host builtins (1)
	Builtin,          // ABC: R[A] = builtin[B](args from R[A+1]..R[A+C])
}

// --- Instruction ---
// Flat interface — no bit packing needed until .msb serialization (Layer 5+).
// Fields a/b/c are 0-255 (u8 range).

export interface RaiserInstruction {
	op: RaiserOpcode;
	a: number;
	b: number;
	c: number;
	cachedIdx: number;  // MIC: cached field index for LoadField/StoreField (-1 = miss)
	line: number;       // Source line number for diagnostics (0 = unknown)
}

// --- Constructors ---

export function raiserABC(op: RaiserOpcode, a: number, b: number, c: number): RaiserInstruction {
	return { op, a, b, c, cachedIdx: -1, line: 0 };
}

export function raiserABx(op: RaiserOpcode, a: number, bx: number): RaiserInstruction {
	const bHigh = (bx / 256) | 0;
	const bLow = bx - bHigh * 256;
	return { op, a, b: bHigh, c: bLow, cachedIdx: -1, line: 0 };
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
	return { op, a: aHigh, b: bMid, c: cLow, cachedIdx: -1, line: 0 };
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
test "ABC round-trip" {
	const inst = raiserABC(RaiserOpcode.AddI64, 2, 0, 1);
	assert inst.op === RaiserOpcode.AddI64;
	assert inst.a === 2;
	assert inst.b === 0;
	assert inst.c === 1;
}

test "ABx round-trip small" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 3, 42);
	assert inst.op === RaiserOpcode.LoadConst;
	assert inst.a === 3;
	assert getBx(inst) === 42;
}

test "ABx round-trip large" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 0, 1000);
	assert getBx(inst) === 1000;
}

test "ABx max value" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 0, 65535);
	assert getBx(inst) === 65535;
}

test "Ax positive jump" {
	const inst = raiserAx(RaiserOpcode.Jump, 10);
	assert inst.op === RaiserOpcode.Jump;
	assert getSignedAx(inst) === 10;
}

test "Ax negative jump" {
	const inst = raiserAx(RaiserOpcode.Jump, -5);
	assert getSignedAx(inst) === -5;
}

test "Ax zero" {
	const inst = raiserAx(RaiserOpcode.Jump, 0);
	assert getSignedAx(inst) === 0;
}

test "signed Bx negative" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 0, 65535);
	assert getSignedBx(inst) === -1;
}

test "signed Bx positive" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 0, 100);
	assert getSignedBx(inst) === 100;
}

test "first opcode is LoadConst" {
	const inst = raiserABC(RaiserOpcode.LoadConst, 0, 0, 0);
	assert inst.op === RaiserOpcode.LoadConst;
}

test "opcodes are distinct" {
	assert RaiserOpcode.AddI64 !== RaiserOpcode.SubI64;
	assert RaiserOpcode.Jump !== RaiserOpcode.Call;
	assert RaiserOpcode.Halt !== RaiserOpcode.Ret;
}
