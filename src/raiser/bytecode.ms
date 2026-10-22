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
	ArraySetLen,      // ABC: R[A].setLength(R[B]) — truncate or nil-extend; C = 1 only checks R[B] is a valid array count (0..2^32-1)

	// Object operations (3)
	NewObject,        // ABC: R[A] = new object; B > 0 gives it class type B - 1 of the function, whose fields it lays out
	LoadField,        // ABC: R[A] = R[B].field(constants[C].text)
	StoreField,       // ABC: R[A].field(constants[B].text) = R[C]

	// String operations (6)
	ConcatStr,        // ABC: R[A] = toString(R[B]) + toString(R[C])
	EqStr,            // ABC: if R[A].text == R[B].text skip C
	NeStr,            // ABC: if R[A].text != R[B].text skip C
	StrLen,           // ABC: R[A] = R[B].text.length
	StrCharAt,        // ABC: R[A] = R[B].text[R[C].intVal] (single char)
	StrSlice,         // ABC: R[A] = R[B].text.slice(R[C].intVal, R[C+1].intVal)

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

	// Host call by name (1)
	// Generic native-call opcode. Name is looked up in the host registry at
	// dispatch time; arguments are marshalled per the registered signature.
	// New stdlib externs require zero VM/codegen edits — they self-register
	// through the host table (see src/compiler/meta/hostTable.ms).
	CallHost,         // ABC: R[A] = hostFn[constants[B].text](R[A+1]..R[A+C])

	// Kind test (1)
	// Compares value KIND (not just intVal). Required because BneI64/BeqI64
	// only look at intVal — Array(handle=0) and Nil both have intVal=0 and
	// would compare equal under BneI64. Codegen emits it with C = Nil whenever
	// either side of === / !== is a NullLiteral, and per variant for `typeof`.
	IsKind,           // ABC: R[A] = (R[B].kind == C) as bool

	// String ordering (2)
	// Nim gives `<`/`<=` on strings their own magics (LtStr/LeStr,
	// lib/system/comparisons.nim) and their own VM opcodes (vmgen.nim:1216) —
	// ordering is NEVER decided by integer comparison. Without these, codegen
	// fell through to BxxI64 and compared string HANDLES. `>`/`>=` need no
	// opcode: Nim derives them by swapping operands, and so does our codegen.
	// ⚠ Appended at the END on purpose — src/raiser/vm_dispatch.c hardcodes
	// opcode NUMBERS, so inserting mid-enum would silently desync it.
	LtStr,            // ABC: if R[A].text < R[B].text skip C
	LeStr,            // ABC: if R[A].text <= R[B].text skip C

	// Strand suspension (1)
	// Hands the turn to the scheduler; the strand resumes at the next
	// instruction. Same append-at-the-END rule as LtStr/LeStr above.
	Yield,            // ABC: suspend the current strand, stay Ready

	// Async surface (2)
	// The runtime pair behind `spawn` / `await`: Spawn starts a strand for a
	// closure pair and hands back the future it will complete; Await reads a
	// future, parking the strand until it is finished. A parked strand
	// re-executes its Await on resume, so no partial-instruction state
	// exists. Same append-at-the-END rule as Yield above.
	Spawn,            // ABC: R[A] = spawn closure R[B]  → future handle
	Await,            // ABC: R[A] = await R[B]          → park until finished

	// Exceptions (5)
	// `Try` pushes a safepoint pointing at the handler metadata; `Catch` is
	// never executed — it only tells the unwinder where the handler body
	// starts and where the guarded block ends. A single untyped catch clause
	// is all the surface has, so there is no chain of typed patterns to walk.
	// Same append-at-the-END rule as the opcodes above.
	Try,              // ABx: push a safepoint at ip + Bx (a Catch or a Finally)
	Catch,            // ABx: metadata — handler body follows, Bx = offset past the block
	Finally,          // ABC: pop the safepoint — reached only when nothing was raised; R[A], R[A+1] = how the finally body was entered
	FinallyEnd,       // ABC: resume what R[A], R[A+1] of its Finally hold: fall through, re-raise, or return
	Throw,            // ABC: raise R[A]

	// Compile-time-known-bad site: the bytecode compiler already reported it
	// (queueRaiserCompileError); executing it is fatal by design — vmError,
	// not a catchable raise, so guest code cannot swallow "the compiler could
	// not compile this". Same append-at-the-END rule as the opcodes above.
	Trap,             // ABx: fatal vmError with message K[Bx]
	NarrowU,          // AB: R[A] = R[A] & ((1 << B) - 1)
	SignExtend,       // AB: R[A] = sign-extend the low B bits of R[A]
	ShiftRightU,      // ABC: R[A] = R[B] >>> R[C]
	Conv,             // ABC: R[A] = R[B] converted to the numeric class RaiserConvClass C
	CopyValue,
	LoadGlobal,
	StoreGlobal,
	StrByteLen,
	Sleep,
	ArraySlice,       // ABC: R[A] = view of R[B] over [R[C], R[C+1]), bounds checked
	BltU64,           // ABC: if R[A] < R[B] as uint64, skip C
	BleU64,           // ABC: if R[A] <= R[B] as uint64, skip C
	DivU64,           // ABC: R[A] = R[B] / R[C] as uint64
	ModU64,           // ABC: R[A] = R[B] % R[C] as uint64
	AddU64,
	SubU64,
	MulU64,
	AddrReg,          // ABC: R[A] = address of R[B]
	AddrGlobal,       // ABx: R[A] = address of global Bx
	AddrIndex,        // ABC: R[A] = address of R[B][R[C]], bounds checked
	AddrField,        // ABC: R[A] = address of field K[C] of R[B]
	LoadDeref,        // ABC: R[A] = R[B][] — an object or array pointer reads as itself
	StoreDeref,       // ABC: R[A][] = R[C]
	SameLoc,          // ABC: R[A] = R[B] and R[C] are the same address (kind, handle, index, field)
	InstanceOf,       // ABC: R[A] = R[B] is an object whose class is K[C] or derives from it
	ObjConv,          // ABC: fatal unless R[A] is nil or an instance of class K[B], named K[C]
	BTruthy,          // ABC: if R[A] is truthy (ToBoolean) skip C
	NarrowS,          // ABC: fatal unless R[A] fits a signed B-bit integer, or an unsigned one when C is 1
	ModuleImport,     // ABx: R[A] = future of import() of the module record named K[Bx]
	FutureNew,        // ABC: R[A] = a pending future
	FutureSettle,     // ABC: complete future R[A] with R[B] unless it is already settled
	FutureFail,       // ABC: fail future R[A] with exception R[B] unless it is already settled
	LoadInt,          // ABC: R[A] = the immediate in B
	AddI64Imm,        // ABC: R[A] = R[B] + the immediate in C, stopping on overflow as AddI64 does
	SubI64Imm,        // ABC: R[A] = R[B] - the immediate in C, stopping on overflow as SubI64 does
	BeqI64Imm,        // ABC: if R[A] == the immediate in B skip C instructions
	BneI64Imm,        // ABC: if R[A] != the immediate in B skip C instructions
	BltI64Imm,        // ABC: if R[A] <  the immediate in B skip C instructions
	BleI64Imm,        // ABC: if R[A] <= the immediate in B skip C instructions
	BgtI64Imm,        // ABC: if R[A] >  the immediate in B skip C instructions
	BgeI64Imm,        // ABC: if R[A] >= the immediate in B skip C instructions
	BrEqI64,          // ABC: if R[A] == R[B] pc += branchOffset(C)
	BrNeI64,          // ABC: if R[A] != R[B] pc += branchOffset(C)
	BrLtI64,          // ABC: if R[A] <  R[B] pc += branchOffset(C)
	BrLeI64,          // ABC: if R[A] <= R[B] pc += branchOffset(C)
	BrGtI64,          // ABC: if R[A] >  R[B] pc += branchOffset(C)
	BrGeI64,          // ABC: if R[A] >= R[B] pc += branchOffset(C)
	BrEqI64Imm,       // ABC: if R[A] == the immediate in B pc += branchOffset(C)
	BrNeI64Imm,       // ABC: if R[A] != the immediate in B pc += branchOffset(C)
	BrLtI64Imm,       // ABC: if R[A] <  the immediate in B pc += branchOffset(C)
	BrLeI64Imm,       // ABC: if R[A] <= the immediate in B pc += branchOffset(C)
	BrGtI64Imm,       // ABC: if R[A] >  the immediate in B pc += branchOffset(C)
	BrGeI64Imm,       // ABC: if R[A] >= the immediate in B pc += branchOffset(C)
	EqVal,            // ABC: if raiserEqual(R[A], R[B]) skip C: kind and payload, a string by text
	NeVal,            // ABC: if !raiserEqual(R[A], R[B]) skip C
	FutureCombine,    // ABC: R[A] = a future settled from the futures in array R[A+1] by RaiserCombine B; Any fails with R[A+2]; C arguments
	Box,              // ABC: R[A] (a Dyn register) = a box holding R[B], or nil when R[B] is nil
	Unbox,            // ABC: R[A] = the value in the box R[B]; a nil box reads as nil, fatal into a Word register
	LoadSlot,         // ABC: LoadField; an object NewObject laid out holds the field at the instruction's slot
	StoreSlot,        // ABC: StoreField; an object NewObject laid out holds the field at the instruction's slot
	MoveW,            // ABC: words[A] = words[B]
	MoveR,            // ABC: refs[A] = refs[B], counted
	BeqR,             // ABC: if refs[A] == refs[B] skip C instructions
	BneR,             // ABC: if refs[A] != refs[B] skip C instructions
	BrEqR,            // ABC: if refs[A] == refs[B] pc += branchOffset(C)
	BrNeR,            // ABC: if refs[A] != refs[B] pc += branchOffset(C)
	LitConv,          // ABC: fatal unless R[A] is nil or one of the literals listed in K[B] (`len:text` each), named K[C]
	CallDirect,       // ABC: Call whose target and signature createRaiserModule checked
}

export const LAST_RAISER_OPCODE: RaiserOpcode = RaiserOpcode.CallDirect;

// How FutureCombine settles its result from its inputs (Promise.all, race, any).
export enum RaiserCombine {
	All,
	Race,
	Any,
}

// A register holds one class for the whole function: Word, Float and Bool live in the word file,
// Ref and Dyn in the ref file. The numbers are the 3-bit class tag of a tagged operand.
export enum RaiserRegClass {
	Word,
	Ref,
	Dyn,
	Float,
	Bool,
}

export function regClassLetter(cls: RaiserRegClass): string {
	return match (cls) {
		RaiserRegClass.Word => "W",
		RaiserRegClass.Ref => "R",
		RaiserRegClass.Dyn => "D",
		RaiserRegClass.Float => "F",
		RaiserRegClass.Bool => "B",
	};
}

export function inRefFile(cls: RaiserRegClass): boolean {
	return cls == RaiserRegClass.Ref || cls == RaiserRegClass.Dyn;
}

export function operandTagged(rank: int32, cls: RaiserRegClass): int32 {
	return (rank << 3) | (cls as int32);
}

export function operandRank(tagged: int32): int32 {
	return tagged >> 3;
}

export function operandClass(tagged: int32): RaiserRegClass {
	return (tagged & 7) as RaiserRegClass;
}

// What an instruction operand is. A fixed role names the class the opcode needs, so the operand
// holds the bare rank in that class's file; Any holds a tagged operand (rank << 3 | class).
// Code reaches createRaiserFunction with one number per register and leaves it renumbered.
export enum RaiserRole {
	None,     // an immediate, a constant index, a count or a site
	Int,      // a Word register
	IntLike,  // a Word or Bool register read for its integer payload
	Float,
	Bool,
	Word,     // any register of the word file, class equal to the other operand
	Ref,
	Dyn,
	Slot,     // any register of the ref file, class equal to the other operand
	Any,      // a register of any class, tagged
	IntPair,  // a Word register followed by the next Word register
	Route,    // a Word register followed by a Dyn register, the second named by B
}

function roleOf(letter: string): RaiserRole {
	return match (letter) {
		"-" => RaiserRole.None,
		"i" => RaiserRole.Int,
		"l" => RaiserRole.IntLike,
		"f" => RaiserRole.Float,
		"b" => RaiserRole.Bool,
		"w" => RaiserRole.Word,
		"r" => RaiserRole.Ref,
		"d" => RaiserRole.Dyn,
		"y" => RaiserRole.Slot,
		"x" => RaiserRole.Any,
		"p" => RaiserRole.IntPair,
		"e" => RaiserRole.Route,
		_ => { throw new Error(`internal: role letter '${letter}' is not defined`); },
	};
}

// One letter for each of A, B and C. A call-like opcode's last operand is a site: its arguments are the registers after A.
function opRoleLetters(op: RaiserOpcode): string {
	return match (op) {
		RaiserOpcode.LoadConst | RaiserOpcode.LoadNil | RaiserOpcode.LoadGlobal | RaiserOpcode.StoreGlobal | RaiserOpcode.Halt | RaiserOpcode.Print
			| RaiserOpcode.Ret | RaiserOpcode.Throw | RaiserOpcode.FutureNew | RaiserOpcode.ModuleImport | RaiserOpcode.Catch | RaiserOpcode.ObjConv | RaiserOpcode.LitConv => "x--",
		RaiserOpcode.Move => "xx-",
		RaiserOpcode.MoveW => "ww-",
		RaiserOpcode.MoveR => "yy-",
		RaiserOpcode.AddI64 | RaiserOpcode.SubI64 | RaiserOpcode.MulI64 | RaiserOpcode.DivI64 | RaiserOpcode.ModI64
			| RaiserOpcode.AddU64 | RaiserOpcode.SubU64 | RaiserOpcode.MulU64 | RaiserOpcode.DivU64 | RaiserOpcode.ModU64
			| RaiserOpcode.BitAnd | RaiserOpcode.BitOr | RaiserOpcode.BitXor
			| RaiserOpcode.ShiftLeft | RaiserOpcode.ShiftRight | RaiserOpcode.ShiftRightU => "iii",
		RaiserOpcode.NegI64 | RaiserOpcode.BitNot => "ii-",
		RaiserOpcode.AddI64Imm | RaiserOpcode.SubI64Imm => "ii-",
		RaiserOpcode.LoadInt | RaiserOpcode.NarrowU | RaiserOpcode.NarrowS | RaiserOpcode.SignExtend => "i--",
		RaiserOpcode.BeqI64 | RaiserOpcode.BneI64 | RaiserOpcode.BltI64 | RaiserOpcode.BleI64 | RaiserOpcode.BgtI64 | RaiserOpcode.BgeI64
			| RaiserOpcode.BrEqI64 | RaiserOpcode.BrNeI64 | RaiserOpcode.BrLtI64 | RaiserOpcode.BrLeI64 | RaiserOpcode.BrGtI64 | RaiserOpcode.BrGeI64 => "ll-",
		RaiserOpcode.BltU64 | RaiserOpcode.BleU64 => "ii-",
		RaiserOpcode.BeqI64Imm | RaiserOpcode.BneI64Imm | RaiserOpcode.BltI64Imm | RaiserOpcode.BleI64Imm | RaiserOpcode.BgtI64Imm | RaiserOpcode.BgeI64Imm
			| RaiserOpcode.BrEqI64Imm | RaiserOpcode.BrNeI64Imm | RaiserOpcode.BrLtI64Imm | RaiserOpcode.BrLeI64Imm | RaiserOpcode.BrGtI64Imm | RaiserOpcode.BrGeI64Imm => "l--",
		RaiserOpcode.BeqR | RaiserOpcode.BneR | RaiserOpcode.BrEqR | RaiserOpcode.BrNeR => "rr-",
		RaiserOpcode.AddF64 | RaiserOpcode.SubF64 | RaiserOpcode.MulF64 | RaiserOpcode.DivF64 => "fff",
		RaiserOpcode.NegF64 => "ff-",
		RaiserOpcode.BeqF64 | RaiserOpcode.BneF64 | RaiserOpcode.BltF64 | RaiserOpcode.BleF64 | RaiserOpcode.BgtF64 | RaiserOpcode.BgeF64 => "ff-",
		RaiserOpcode.BTruthy => "x--",
		RaiserOpcode.IsKind | RaiserOpcode.InstanceOf => "bx-",
		RaiserOpcode.SameLoc => "bxx",
		RaiserOpcode.EqVal | RaiserOpcode.NeVal => "xx-",
		RaiserOpcode.Conv => "xx-",
		RaiserOpcode.CopyValue => "xx-",
		RaiserOpcode.Box => "dx-",
		RaiserOpcode.Unbox => "xd-",
		RaiserOpcode.NewArray | RaiserOpcode.NewObject => "r--",
		RaiserOpcode.LoadIndex => "xri",
		RaiserOpcode.StoreIndex => "rix",
		RaiserOpcode.ArrayLen => "ir-",
		RaiserOpcode.ArrayPush => "rx-",
		RaiserOpcode.ArraySetLen => "ri-",
		RaiserOpcode.ArraySlice => "rrp",
		RaiserOpcode.LoadField | RaiserOpcode.LoadSlot => "xr-",
		RaiserOpcode.StoreField | RaiserOpcode.StoreSlot => "r-x",
		RaiserOpcode.ConcatStr => "rxx",
		RaiserOpcode.EqStr | RaiserOpcode.NeStr | RaiserOpcode.LtStr | RaiserOpcode.LeStr => "rr-",
		RaiserOpcode.StrLen | RaiserOpcode.StrByteLen => "ir-",
		RaiserOpcode.StrCharAt => "rri",
		RaiserOpcode.StrSlice => "rrp",
		RaiserOpcode.AddrReg => "dx-",
		RaiserOpcode.AddrGlobal => "d--",
		RaiserOpcode.AddrIndex => "dri",
		RaiserOpcode.AddrField => "dr-",
		RaiserOpcode.LoadDeref => "xx-",
		RaiserOpcode.StoreDeref => "x-x",
		RaiserOpcode.Call | RaiserOpcode.CallDirect | RaiserOpcode.CallHost | RaiserOpcode.FutureCombine => "x--",
		RaiserOpcode.CallIndirect => "xi-",
		RaiserOpcode.Spawn | RaiserOpcode.Await | RaiserOpcode.FutureSettle | RaiserOpcode.FutureFail => "xx-",
		RaiserOpcode.Sleep => "xx-",
		RaiserOpcode.Finally | RaiserOpcode.FinallyEnd => "e--",
		RaiserOpcode.Jump | RaiserOpcode.Try | RaiserOpcode.Yield | RaiserOpcode.Trap => "---",
	};
}

export function opRole(op: RaiserOpcode, slot: int32): RaiserRole {
	return roleOf(opRoleLetters(op).charAt(slot));
}

// What a generic handler finds in an operand once it is retagged: 0..4 is the class a fixed role names,
// OPERAND_TAGGED an operand that already carries its class, OPERAND_RAW one that is no register, and
// OPERAND_BARE a bare rank whose class the role leaves open (only the typed handlers read those).
export const OPERAND_TAGGED: int32 = 5;
export const OPERAND_RAW: int32 = 6;
export const OPERAND_BARE: int32 = 7;

export function operandKind(op: RaiserOpcode, slot: int32): int32 {
	return match (opRole(op, slot)) {
		RaiserRole.None => OPERAND_RAW,
		RaiserRole.Int | RaiserRole.IntPair | RaiserRole.Route => RaiserRegClass.Word as int32,
		RaiserRole.Float => RaiserRegClass.Float as int32,
		RaiserRole.Bool => RaiserRegClass.Bool as int32,
		RaiserRole.Ref => RaiserRegClass.Ref as int32,
		RaiserRole.Dyn => RaiserRegClass.Dyn as int32,
		RaiserRole.Any => OPERAND_TAGGED,
		_ => OPERAND_BARE,
	};
}

export function opHasSite(op: RaiserOpcode): boolean {
	return op == RaiserOpcode.Call || op == RaiserOpcode.CallDirect || op == RaiserOpcode.CallIndirect || op == RaiserOpcode.CallHost || op == RaiserOpcode.FutureCombine || op == RaiserOpcode.NewArray;
}

// How many registers follow A as the arguments of a site opcode: the count sits in C, or in B for NewArray.
export function siteArgCount(inst: RaiserInstruction): number {
	return inst.op == RaiserOpcode.NewArray ? inst.b : inst.c;
}

export enum RaiserConvClass {
	F64,
	I64,
	I32,
	I16,
	I8,
	U64,
	U32,
	U16,
	U8,
	F32,
	Str,
	F64Bits,
	HandleBits,
	I32Wrap,
	Char,
}

export function convOperand(to: RaiserConvClass, from: int32): int32 {
	return (to as int32) | ((from + 1) << 4);
}

export function convTarget(c: number): RaiserConvClass {
	return ((c as int32) & 15) as RaiserConvClass;
}

export function convSource(c: number): int32 {
	return ((c as int32) >> 4) - 1;
}

export function convClassBits(cls: RaiserConvClass): int32 {
	return match (cls) {
		RaiserConvClass.I32 | RaiserConvClass.U32 => 32,
		RaiserConvClass.I16 | RaiserConvClass.U16 => 16,
		RaiserConvClass.I8 | RaiserConvClass.U8 => 8,
		_ => 64,
	};
}

export function convClassSigned(cls: RaiserConvClass): boolean {
	return match (cls) {
		RaiserConvClass.I64 | RaiserConvClass.I32 | RaiserConvClass.I16 | RaiserConvClass.I8 => true,
		_ => false,
	};
}

// --- Instruction ---
// The record codegen builds and the disassembler reads. The VM runs the packed
// form of it (packInstruction).

export interface RaiserInstruction {
	op: RaiserOpcode;
	a: number;
	b: number;
	c: number;
	line: number;       // Source line number for diagnostics (0 = unknown)
	slot: number;       // LoadSlot/StoreSlot: the field's slot in the receiver type's layout, packed in the top byte
}

// --- Constructors ---

export function raiserABC(op: RaiserOpcode, a: number, b: number, c: number): RaiserInstruction {
	return { op, a, b, c, line: 0, slot: 0 };
}

export function raiserABx(op: RaiserOpcode, a: number, bx: number): RaiserInstruction {
	const bHigh: int32 = (bx as int32 / 256) | 0;
	const bLow = bx - (bHigh as number) * 256;
	return { op, a, b: bHigh as number, c: bLow, line: 0, slot: 0 };
}

export function raiserAx(op: RaiserOpcode, ax: number): RaiserInstruction {
	// 24-bit signed → split into a(high8), b(mid8), c(low8)
	// For negative values, add 2^24 to get unsigned representation
	let raw = ax;
	if (raw < 0) { raw = raw + 16777216; }
	const aHigh: int32 = (raw as int32 / 65536) | 0;
	const rem = raw - (aHigh as number) * 65536;
	const bMid: int32 = (rem as int32 / 256) | 0;
	const cLow = rem - (bMid as number) * 256;
	return { op, a: aHigh as number, b: bMid as number, c: cLow, line: 0, slot: 0 };
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

const IMM_EXCESS = 32768;

export function fitsImm(v: int64): boolean {
	return v >= -IMM_EXCESS && v < IMM_EXCESS;
}

export function immField(v: int64): number {
	if (!fitsImm(v)) throw new Error(`internal: immediate ${v} does not fit the 16-bit operand field`);
	return (v + IMM_EXCESS) as number;
}

export function immValue(field: number): int64 {
	return (field as int64) - IMM_EXCESS;
}

const BRANCH_EXCESS = 8388608;

export function isBranchI64(op: RaiserOpcode): boolean {
	return match (op) {
		RaiserOpcode.BrEqI64 | RaiserOpcode.BrNeI64 | RaiserOpcode.BrLtI64 | RaiserOpcode.BrLeI64 | RaiserOpcode.BrGtI64 | RaiserOpcode.BrGeI64
			| RaiserOpcode.BrEqI64Imm | RaiserOpcode.BrNeI64Imm | RaiserOpcode.BrLtI64Imm | RaiserOpcode.BrLeI64Imm
			| RaiserOpcode.BrGtI64Imm | RaiserOpcode.BrGeI64Imm | RaiserOpcode.BrEqR | RaiserOpcode.BrNeR => true,
		_ => false,
	};
}

export function branchField(offset: int64): number {
	if (offset < -BRANCH_EXCESS || offset >= BRANCH_EXCESS) throw new Error(`internal: branch offset ${offset} does not fit the 24-bit branch field`);
	return (offset + BRANCH_EXCESS) as number;
}

export function branchOffset(field: number): int64 {
	return (field as int64) - BRANCH_EXCESS;
}

// Packed word: opcode in bits 0-7, then a, b and c in 16 bits each; a branch's offset and a jump's take the 24 bits
// from bit 40 up as a signed field, and a slot opcode's slot the top 8.
const PACKED_FIELD_LIMIT = 65536;
export const MAX_SLOT = 255;
const PACKED_BRANCH_LIMIT = 16777216;

function packedField(inst: RaiserInstruction, v: number, name: string, limit: int64, bits: int32): int64 {
	const whole = v as int64;
	if ((whole as number) != v || whole < 0 || whole >= limit) {
		throw new Error(`internal: operand ${name} = ${v} of opcode ${inst.op} does not fit the packed ${bits}-bit field`);
	}
	return whole;
}

export function packedOp(word: int64): RaiserOpcode {
	return (word & 255) as RaiserOpcode;
}

export function packedA(word: int64): number {
	return ((word >> 8) & 65535) as number;
}

export function packedB(word: int64): number {
	return ((word >> 24) & 65535) as number;
}

export function packedBx(word: int64): number {
	return (((word >> 24) & 65535) * 256 + ((word >> 40) & 65535)) as number;
}

export function packedBranch(word: int64): int32 {
	return (word >> 40) as int32;
}

export function packInstruction(inst: RaiserInstruction): int64 {
	const op = inst.op as int64;
	if (op < 0 || op > 255) throw new Error(`internal: opcode ${inst.op} does not fit the packed 8-bit field`);
	if (inst.op == RaiserOpcode.Jump) {
		const offset = getSignedAx(inst) as int64;
		if (inst.a >= 256 || offset < -BRANCH_EXCESS || offset >= BRANCH_EXCESS) throw new Error(`internal: jump offset ${offset} does not fit the packed 24-bit field`);
		return op | (offset << 40);
	}
	const c = isBranchI64(inst.op) ? branchOffset(packedField(inst, inst.c, "c", PACKED_BRANCH_LIMIT, 24) as number) << 40 : packedField(inst, inst.c, "c", PACKED_FIELD_LIMIT, 16) << 40;
	const slot = inst.op == RaiserOpcode.LoadSlot || inst.op == RaiserOpcode.StoreSlot ? packedField(inst, inst.slot, "slot", MAX_SLOT + 1, 8) << 56 : 0;
	return op | (packedField(inst, inst.a, "a", PACKED_FIELD_LIMIT, 16) << 8) | (packedField(inst, inst.b, "b", PACKED_FIELD_LIMIT, 16) << 24) | c | slot;
}

// --- Tests ---
test "ABC round-trip" {
	const inst = raiserABC(RaiserOpcode.AddI64, 2, 0, 1);
	assert inst.op == RaiserOpcode.AddI64;
	assert inst.a == 2;
	assert inst.b == 0;
	assert inst.c == 1;
}

test "ABx round-trip small" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 3, 42);
	assert inst.op == RaiserOpcode.LoadConst;
	assert inst.a == 3;
	assert getBx(inst) == 42;
}

test "ABx round-trip large" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 0, 1000);
	assert getBx(inst) == 1000;
}

test "ABx max value" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 0, 65535);
	assert getBx(inst) == 65535;
}

test "Ax positive jump" {
	const inst = raiserAx(RaiserOpcode.Jump, 10);
	assert inst.op == RaiserOpcode.Jump;
	assert getSignedAx(inst) == 10;
}

test "Ax negative jump" {
	const inst = raiserAx(RaiserOpcode.Jump, -5);
	assert getSignedAx(inst) == -5;
}

test "Ax zero" {
	const inst = raiserAx(RaiserOpcode.Jump, 0);
	assert getSignedAx(inst) == 0;
}

test "signed Bx negative" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 0, 65535);
	assert getSignedBx(inst) == -1;
}

test "signed Bx positive" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 0, 100);
	assert getSignedBx(inst) == 100;
}

test "first opcode is LoadConst" {
	const inst = raiserABC(RaiserOpcode.LoadConst, 0, 0, 0);
	assert inst.op == RaiserOpcode.LoadConst;
}

test "opcodes are distinct" {
	assert RaiserOpcode.AddI64 != RaiserOpcode.SubI64;
	assert RaiserOpcode.Jump != RaiserOpcode.Call;
	assert RaiserOpcode.Halt != RaiserOpcode.Ret;
}

test "CallHost ABC round-trip" {
	// A = dst register, B = name constant index, C = argc
	const inst = raiserABC(RaiserOpcode.CallHost, 3, 7, 2);
	assert inst.op == RaiserOpcode.CallHost;
	assert inst.a == 3;
	assert inst.b == 7;
	assert inst.c == 2;
}

test "CallHost zero args" {
	// Edge case: void-arg native (e.g., msFsLastErrno)
	const inst = raiserABC(RaiserOpcode.CallHost, 0, 0, 0);
	assert inst.op == RaiserOpcode.CallHost;
	assert inst.c == 0;
}

test "packed word holds op, a, b and c" {
	const w = packInstruction(raiserABC(RaiserOpcode.AddI64, 65535, 1000, 7));
	assert (w & 255) == (RaiserOpcode.AddI64 as int64);
	assert ((w >> 8) & 65535) == 65535;
	assert ((w >> 24) & 65535) == 1000;
	assert ((w >> 40) & 65535) == 7;
}

test "packed word keeps a jump's signed offset in one field" {
	for (const offset of [0, 1, -1, -5, 32768, -32769, 8388607, -8388608]) {
		const w = packInstruction(raiserAx(RaiserOpcode.Jump, offset));
		assert packedOp(w) == RaiserOpcode.Jump && packedBranch(w) == offset;
	}
}

test "an operand outside 16 bits stops the pack" {
	let message = "";
	try {
		packInstruction(raiserABC(RaiserOpcode.Move, 65536, 0, 0));
	} catch (e) {
		message = (e as Error).message;
	}
	assert message.includes("does not fit the packed 16-bit field");
}

test "an immediate keeps its value across the field and stops one past each end" {
	assert immValue(immField(-32768)) == -32768;
	assert immValue(immField(32767)) == 32767;
	assert immValue(immField(0)) == 0;
	assert immField(-32768) == 0 && immField(32767) == 65535;
	assert fitsImm(32767) && fitsImm(-32768) && !fitsImm(32768) && !fitsImm(-32769);
	let message = "";
	try {
		immField(32768);
	} catch (e) {
		message = (e as Error).message;
	}
	assert message.includes("does not fit the 16-bit operand field");
}

test "a branch offset keeps its sign across the 24-bit packed field and stops one past each end" {
	for (const offset of [0, 1, -1, 32768, -32769, 8388607, -8388608]) {
		const inst = raiserABC(RaiserOpcode.BrLtI64, 3, 4, branchField(offset));
		assert packedBranch(packInstruction(inst)) == offset;
		assert packedA(packInstruction(inst)) == 3;
	}
	let message = "";
	try {
		branchField(8388608);
	} catch (e) {
		message = (e as Error).message;
	}
	assert message.includes("does not fit the 24-bit branch field");
	let wide = "";
	try {
		packInstruction(raiserABC(RaiserOpcode.BltI64, 0, 0, 65536));
	} catch (e) {
		wide = (e as Error).message;
	}
	assert wide.includes("does not fit the packed 16-bit field");
}
