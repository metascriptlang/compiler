// Raiser VM — register layout: class inference for hand-built code and the operand verifier. A register's number is
// its slot in the frame.

import {
	RaiserOpcode, RaiserInstruction, TYPED_SLOTS, RaiserRegClass, RaiserRole, RaiserConvClass, regClassLetter, inRefFile, operandTagged,
	opRole, opHasSite, siteArgCount, convTarget, convSource, raiserABC, raiserABx
} from "./bytecode";
import { RaiserValue, RaiserValueKind, raiserBool } from "./value";
import { MemKind } from "./layout";

const MAX_TAGGED_RANK: int32 = 8191;
const MAX_FIELD: int32 = 65535;
const MAX_SIG_ARGS: int32 = 20;

export interface RaiserRegLayout {
	code: RaiserInstruction[];
	regClasses: RaiserRegClass[];
	regOps: int32[];       // the tagged operand of each input register
	blocks: int64[];       // per site: the callee's first slot, argument count, class signature, then one tagged operand per argument
	sigs: int64[];         // sigs[n] is the class signature of the first n registers, for a callee's parameters
}

const CLASS_WORD: int32 = 1;
const CLASS_REF: int32 = 2;
const CLASS_DYN: int32 = 4;
const CLASS_FLOAT: int32 = 8;
const CLASS_BOOL: int32 = 16;
const CLASS_ALL: int32 = 31;

function classBit(cls: RaiserRegClass): int32 {
	return 1 << (cls as int32);
}

function roleMask(role: RaiserRole): int32 {
	return match (role) {
		RaiserRole.Int | RaiserRole.IntPair => CLASS_WORD,
		RaiserRole.IntLike => CLASS_WORD | CLASS_BOOL,
		RaiserRole.Float => CLASS_FLOAT,
		RaiserRole.Bool => CLASS_BOOL,
		RaiserRole.Word => CLASS_WORD | CLASS_FLOAT | CLASS_BOOL,
		RaiserRole.Ref => CLASS_REF,
		RaiserRole.Dyn => CLASS_DYN,
		RaiserRole.Slot => CLASS_REF | CLASS_DYN,
		RaiserRole.Route => CLASS_WORD,
		_ => CLASS_ALL,
	};
}

function isFrameData(op: RaiserOpcode): boolean {
	return op == RaiserOpcode.MoveN || op == RaiserOpcode.ZeroN ||
		op == RaiserOpcode.LoadFrame || op == RaiserOpcode.StoreFrame;
}

function frameScalarWidth(kind: number): int32 {
	return match (kind as MemKind) {
		MemKind.I8 | MemKind.U8 => 1,
		MemKind.I16 | MemKind.U16 => 2,
		MemKind.I32 | MemKind.U32 | MemKind.F32 => 4,
		MemKind.I64 | MemKind.U64 | MemKind.F64 | MemKind.Ptr => 8,
		_ => 0,
	};
}

function frameScalarMask(kind: number): int32 {
	if (kind == (MemKind.U8 as number)) return CLASS_WORD | CLASS_BOOL;
	return kind == (MemKind.F32 as number) || kind == (MemKind.F64 as number)
		? CLASS_FLOAT : CLASS_WORD;
}

function frameWordCount(inst: RaiserInstruction): int32 {
	if (inst.op == RaiserOpcode.MoveN) return inst.c as int32;
	if (inst.op == RaiserOpcode.ZeroN) return inst.b as int32;
	const offset = inst.op == RaiserOpcode.LoadFrame ? inst.c : inst.b;
	return ((offset as int32) + frameScalarWidth(inst.slot) + 7) / 8;
}

function frameBase(inst: RaiserInstruction): int32 {
	return (inst.op == RaiserOpcode.LoadFrame ? inst.b : inst.a) as int32;
}

function validateWordRange(name: string, pc: int32, base: int32, count: int32, regCount: int32): void {
	if (count <= 0) {
		throw new Error(`internal: frame data instruction ${pc} of ${name} needs a positive Word count`);
	}
	if (base >= regCount || count > regCount - base) {
		throw new Error(`internal: frame data instruction ${pc} of ${name} spans R${base} for ${count} Words past the frame of ${regCount}`);
	}
}

function validateFrameData(name: string, pc: int32, inst: RaiserInstruction, regCount: int32): void {
	for (const value of [inst.a, inst.b, inst.c]) {
		if (value != value || value < 0 || value > MAX_FIELD || value != ((value as int32) as number)) {
			throw new Error(`internal: frame data instruction ${pc} of ${name} has invalid packed operand ${value}`);
		}
	}
	if (inst.op == RaiserOpcode.LoadFrame || inst.op == RaiserOpcode.StoreFrame) {
		if (inst.slot != inst.slot || inst.slot < (MemKind.I8 as number) ||
			inst.slot > (MemKind.Ptr as number) ||
			inst.slot != ((inst.slot as int32) as number)) {
			throw new Error(`internal: frame data instruction ${pc} of ${name} has invalid scalar MemKind ${inst.slot}`);
		}
		const width = frameScalarWidth(inst.slot);
		const offset = (inst.op == RaiserOpcode.LoadFrame ? inst.c : inst.b) as int32;
		if (offset % width != 0) {
			throw new Error(`internal: frame data instruction ${pc} of ${name} has unaligned byte offset ${offset} for width ${width}`);
		}
	}
	const count = frameWordCount(inst);
	validateWordRange(name, pc, frameBase(inst), count, regCount);
	if (inst.op == RaiserOpcode.MoveN) {
		validateWordRange(name, pc, inst.b as int32, count, regCount);
	}
}

function narrowWordRange(mask: int32[], base: int32, count: int32): boolean {
	let changed = false;
	for (let r = base; r < base + count; r += 1) {
		if (narrowMask(mask, r, CLASS_WORD)) changed = true;
	}
	return changed;
}

function verifyWordRange(name: string, pc: int32, classes: RaiserRegClass[], base: int32, count: int32): void {
	for (let r = base; r < base + count; r += 1) {
		if (classes[r] != RaiserRegClass.Word) {
			throw new Error(`internal: frame data instruction ${pc} of ${name}: R${r} is not opaque Word storage`);
		}
	}
}

function constantMask(c: RaiserValue): int32 {
	return match (c.kind) {
		RaiserValueKind.Int => CLASS_WORD,
		RaiserValueKind.Float => CLASS_FLOAT,
		RaiserValueKind.Bool => CLASS_BOOL,
		RaiserValueKind.Nil => CLASS_REF | CLASS_DYN,
		RaiserValueKind.String => CLASS_REF,
		_ => CLASS_ALL,
	};
}

function convDestMask(c: number): int32 {
	const target = convTarget(c);
	if (target == RaiserConvClass.F64 || target == RaiserConvClass.F32) return CLASS_FLOAT;
	if (target == RaiserConvClass.Str) return CLASS_REF;
	return CLASS_WORD;
}

function maskText(mask: int32): string {
	let text = "";
	for (let c = 0; c < 5; c += 1) {
		if ((mask & (1 << c)) != 0) text = text + regClassLetter(c as RaiserRegClass);
	}
	return text == "" ? "none" : text;
}

function registerOf(inst: RaiserInstruction, slot: int32): int32 {
	return (slot == 0 ? inst.a : slot == 1 ? inst.b : inst.c) as int32;
}

function narrowMask(mask: int32[], reg: int32, allowed: int32): boolean {
	if (reg < 0 || reg >= mask.length) return false;
	const next = mask[reg] & allowed;
	if (next == mask[reg]) return false;
	mask[reg] = next;
	return true;
}

// The classes a register may hold after every operand that names it has spoken. A function built without
// declared classes takes the first of Word, Ref, Float, Bool, Dyn that all of its uses allow, and Dyn when no use names a class.
export function inferClasses(name: string, code: RaiserInstruction[], constants: RaiserValue[], regCount: int32): RaiserRegClass[] {
	for (let pc = 0; pc < code.length; pc += 1) {
		if (isFrameData(code[pc].op)) validateFrameData(name, pc, code[pc], regCount);
	}
	const mask: int32[] = [];
	for (let r = 0; r < regCount; r += 1) mask.push(CLASS_ALL);
	let changed = true;
	while (changed) {
		changed = false;
		for (const inst of code) {
			const op = inst.op;
			if (isFrameData(op)) {
				const count = frameWordCount(inst);
				if (narrowWordRange(mask, frameBase(inst), count)) changed = true;
				if (op == RaiserOpcode.MoveN && narrowWordRange(mask, inst.b as int32, count)) changed = true;
				if (op == RaiserOpcode.LoadFrame || op == RaiserOpcode.StoreFrame) {
					const scalar = (op == RaiserOpcode.LoadFrame ? inst.a : inst.c) as int32;
					if (narrowMask(mask, scalar, frameScalarMask(inst.slot))) changed = true;
				}
			}
			if (op == RaiserOpcode.LoadConst && inst.a < regCount) {
				const index = (inst.b * 256 + inst.c) as int32;
				if (index < constants.length && narrowMask(mask, inst.a as int32, constantMask(constants[index]))) changed = true;
			}
			if (op == RaiserOpcode.Conv && narrowMask(mask, inst.a as int32, convDestMask(inst.c))) changed = true;
			if (op == RaiserOpcode.Move && inst.a < regCount && inst.b < regCount) {
				const joined = mask[inst.a as int32] & mask[inst.b as int32];
				if (narrowMask(mask, inst.a as int32, joined)) changed = true;
				if (narrowMask(mask, inst.b as int32, joined)) changed = true;
			}
			for (let slot = 0; slot < 3; slot += 1) {
				const role = opRole(op, slot);
				if (role == RaiserRole.None || role == RaiserRole.Any || role == RaiserRole.Route && slot != 0) continue;
				if (op == RaiserOpcode.Move) continue;
				const reg = registerOf(inst, slot);
				if (narrowMask(mask, reg, roleMask(role))) changed = true;
				if (role == RaiserRole.IntPair && narrowMask(mask, reg + 1, CLASS_WORD)) changed = true;
				if (role == RaiserRole.Route && narrowMask(mask, reg + 1, CLASS_DYN)) changed = true;
			}
		}
	}
	const classes: RaiserRegClass[] = [];
	for (let r = 0; r < regCount; r += 1) {
		const m = mask[r];
		if (m == 0) throw new Error(`internal: register R${r} of ${name} is used as classes that no class satisfies`);
		classes.push(m == CLASS_ALL ? RaiserRegClass.Dyn : (m & CLASS_WORD) != 0 ? RaiserRegClass.Word : (m & CLASS_REF) != 0 ? RaiserRegClass.Ref : (m & CLASS_FLOAT) != 0 ? RaiserRegClass.Float : (m & CLASS_BOOL) != 0 ? RaiserRegClass.Bool : RaiserRegClass.Dyn);
	}
	return classes;
}

function classMismatch(name: string, pc: int32, inst: RaiserInstruction, slot: int32, reg: int32, cls: RaiserRegClass, role: RaiserRole): Error {
	const operand = slot == 0 ? "A" : slot == 1 ? "B" : "C";
	return new Error(`internal: operand ${operand} of instruction ${pc} (opcode ${inst.op}) of ${name} is R${reg}, a ${regClassLetter(cls)} register, where the opcode needs ${maskText(roleMask(role))}`);
}

function signatureOf(classes: RaiserRegClass[], first: int32, count: int32): int64 {
	if (count > MAX_SIG_ARGS) return -1;
	let sig: int64 = 0;
	for (let i = 0; i < count; i += 1) sig = sig | ((classes[first + i] as int64) << ((3 * i) as int64));
	return sig;
}

function ranked(op: RaiserOpcode, a: RaiserRegClass): RaiserOpcode {
	if (a != RaiserRegClass.Ref) return op;
	return match (op) {
		RaiserOpcode.BeqI64 => RaiserOpcode.BeqR,
		RaiserOpcode.BneI64 => RaiserOpcode.BneR,
		RaiserOpcode.BrEqI64 => RaiserOpcode.BrEqR,
		RaiserOpcode.BrNeI64 => RaiserOpcode.BrNeR,
		_ => op,
	};
}

// A Conv from a Word register to F64 is the plain integer conversion, signed unless its source is U64; one from F64 bits
// stays a Conv.
function typedConv(inst: RaiserInstruction, classes: RaiserRegClass[], regCount: int32): RaiserOpcode {
	if (inst.a >= regCount || inst.b >= regCount || convTarget(inst.c) != RaiserConvClass.F64) return RaiserOpcode.Conv;
	if (classes[inst.a as int32] != RaiserRegClass.Float || classes[inst.b as int32] != RaiserRegClass.Word) return RaiserOpcode.Conv;
	const from = convSource(inst.c);
	if (from == (RaiserConvClass.U64 as int32)) return RaiserOpcode.UIntToF64;
	return from == (RaiserConvClass.F64Bits as int32) ? RaiserOpcode.Conv : RaiserOpcode.IntToF64;
}

function typedSlot(op: RaiserOpcode, value: RaiserRegClass): RaiserOpcode {
	if (value == RaiserRegClass.Word) return op == RaiserOpcode.LoadSlot ? RaiserOpcode.LoadSlotW : RaiserOpcode.StoreSlotW;
	if (value == RaiserRegClass.Ref) return op == RaiserOpcode.LoadSlot ? RaiserOpcode.LoadSlotR : RaiserOpcode.StoreSlotR;
	return op;
}

// Checks every operand of every instruction against its role and renumbers the registers; a function that
// breaks a role stops here, with the instruction and the register named.
export function layoutRegisters(name: string, code: RaiserInstruction[], constants: RaiserValue[], regCount: int32, declared: RaiserRegClass[] | null): RaiserRegLayout {
	const classes = declared != null ? declared : inferClasses(name, code, constants, regCount);
	if (classes.length != regCount) throw new Error(`internal: function ${name} has ${regCount} registers but ${classes.length} register classes`);
	const regOps: int32[] = [];
	for (let r = 0; r < regCount; r += 1) regOps.push(operandTagged(r, classes[r]));
	const out: RaiserInstruction[] = [];
	const blocks: int64[] = [];
	for (let pc = 0; pc < code.length; pc += 1) {
		const inst = code[pc];
		let op = inst.op;
		if (isFrameData(op)) {
			validateFrameData(name, pc, inst, regCount);
			const count = frameWordCount(inst);
			verifyWordRange(name, pc, classes, frameBase(inst), count);
			if (op == RaiserOpcode.MoveN) verifyWordRange(name, pc, classes, inst.b as int32, count);
			if (op == RaiserOpcode.LoadFrame || op == RaiserOpcode.StoreFrame) {
				const scalar = (op == RaiserOpcode.LoadFrame ? inst.a : inst.c) as int32;
				if (scalar >= regCount || (classBit(classes[scalar]) & frameScalarMask(inst.slot)) == 0) {
					throw new Error(`internal: frame data instruction ${pc} of ${name}: R${scalar} has incompatible scalar class for MemKind ${inst.slot}`);
				}
			}
		}
		if (op == RaiserOpcode.Move) {
			const ca = inst.a < regCount ? classes[inst.a as int32] : RaiserRegClass.Dyn;
			const cb = inst.b < regCount ? classes[inst.b as int32] : RaiserRegClass.Dyn;
			if (inst.a >= regCount || inst.b >= regCount || ca != cb) throw new Error(`internal: Move at instruction ${pc} of ${name} copies R${inst.b} (${inst.b < regCount ? regClassLetter(cb) : "none"}) to R${inst.a} (${inst.a < regCount ? regClassLetter(ca) : "none"}) across register classes`);
			op = inRefFile(ca) ? RaiserOpcode.MoveR : RaiserOpcode.MoveW;
		}
		if (op == RaiserOpcode.LoadSlot && inst.a < regCount && inst.slot < TYPED_SLOTS) op = typedSlot(op, classes[inst.a as int32]);
		if (op == RaiserOpcode.StoreSlot && inst.c < regCount && inst.slot < TYPED_SLOTS) op = typedSlot(op, classes[inst.c as int32]);
		if (inst.a < regCount && (op == RaiserOpcode.BeqI64 || op == RaiserOpcode.BneI64 || op == RaiserOpcode.BrEqI64 || op == RaiserOpcode.BrNeI64)) op = ranked(op, classes[inst.a as int32]);
		if (op == RaiserOpcode.Conv) op = typedConv(inst, classes, regCount);
		if (op == RaiserOpcode.LoadConst && inst.a < regCount && (inst.b * 256 + inst.c) < constants.length && !inRefFile(classes[inst.a as int32])) op = RaiserOpcode.LoadConstW;
		const fields: int32[] = [inst.a as int32, inst.b as int32, inst.c as int32];
		for (let slot = 0; slot < 3; slot += 1) {
			const role = opRole(op, slot);
			if (role == RaiserRole.None) continue;
			const reg = fields[slot];
			if (reg < 0 || reg >= regCount) throw new Error(`internal: instruction ${pc} (opcode ${inst.op}) of ${name} names register R${reg} of ${regCount}`);
			const cls = classes[reg];
			if ((roleMask(role) & classBit(cls)) == 0) throw classMismatch(name, pc, inst, slot, reg, cls, role);
			if (role == RaiserRole.IntPair && (reg + 1 >= regCount || classes[reg + 1] != RaiserRegClass.Word)) throw classMismatch(name, pc, inst, slot, reg + 1, reg + 1 < regCount ? classes[reg + 1] : RaiserRegClass.Dyn, role);
			if (role == RaiserRole.Route) {
				if (reg + 1 >= regCount || classes[reg + 1] != RaiserRegClass.Dyn) throw classMismatch(name, pc, inst, slot, reg + 1, reg + 1 < regCount ? classes[reg + 1] : RaiserRegClass.Word, role);
				fields[1] = regOps[reg + 1] >> 3;
			}
			const rank = regOps[reg] >> 3;
			if (role == RaiserRole.Any ? rank > MAX_TAGGED_RANK : rank > MAX_FIELD) throw new Error(`internal: operand ${slot == 0 ? "A" : slot == 1 ? "B" : "C"} of instruction ${pc} of ${name} names R${reg}, which is rank ${rank} of its file, past what an operand of this opcode holds`);
			fields[slot] = role == RaiserRole.Any ? regOps[reg] : rank;
		}
		if (op == RaiserOpcode.LoadConst || op == RaiserOpcode.LoadConstW) {
			const index = (inst.b * 256 + inst.c) as int32;
			const dest = classes[inst.a as int32];
			if (index < constants.length && (constantMask(constants[index]) & classBit(dest)) == 0) throw new Error(`internal: LoadConst at instruction ${pc} of ${name} loads a constant of value kind ${constants[index].kind} into R${inst.a}, a ${regClassLetter(dest)} register`);
		}
		if (op == RaiserOpcode.Conv && (convDestMask(inst.c) & classBit(classes[inst.a as int32])) == 0) throw new Error(`internal: Conv at instruction ${pc} of ${name} writes R${inst.a}, a ${regClassLetter(classes[inst.a as int32])} register, where its target class needs ${maskText(convDestMask(inst.c))}`);
		let c = fields[2];
		if (opHasSite(op)) {
			const argc = siteArgCount(inst) as int32;
			const first = (inst.a as int32) + 1;
			if (first + argc > regCount) throw new Error(`internal: instruction ${pc} (opcode ${inst.op}) of ${name} has ${argc} arguments after R${inst.a} but only ${regCount} registers`);
			c = blocks.length;
			if (c > 65535) throw new Error(`internal: function ${name} has more call sites than a site index holds`);
			blocks.push(first as int64);
			blocks.push(argc as int64);
			blocks.push(signatureOf(classes, first, argc));
			for (let i = 0; i < argc; i += 1) blocks.push(regOps[first + i] as int64);
		}
		const result = raiserABC(op, fields[0], fields[1], c);
		result.line = inst.line;
		result.slot = inst.slot;
		result.site = inst.site;
		out.push(result);
	}
	const sigs: int64[] = [];
	const sigLimit = regCount < MAX_SIG_ARGS ? regCount : MAX_SIG_ARGS;
	for (let n = 0; n <= sigLimit; n += 1) sigs.push(signatureOf(classes, 0, n));
	return { code: out, regClasses: classes, regOps, blocks, sigs };
}

function refusal(code: RaiserInstruction[], classes: RaiserRegClass[], inferred: boolean = false): string {
	try {
		layoutRegisters("probe", code, [], classes.length, inferred ? null : classes);
	} catch (e) {
		return (e as Error).message;
	}
	return "";
}

test "an operand of a class its role does not name is refused with the instruction and the register" {
	const words = [RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Word];
	assert refusal([raiserABC(RaiserOpcode.AddI64, 2, 0, 1)], words) == "";
	const float = refusal([raiserABC(RaiserOpcode.AddI64, 2, 0, 1)], [RaiserRegClass.Word, RaiserRegClass.Float, RaiserRegClass.Word]);
	assert float.indexOf("operand C of instruction 0") >= 0 && float.indexOf("R1, a F register, where the opcode needs W") >= 0, float;
	const ref = refusal([raiserABC(RaiserOpcode.AddI64, 2, 0, 1)], [RaiserRegClass.Ref, RaiserRegClass.Word, RaiserRegClass.Word]);
	assert ref.indexOf("operand B of instruction 0") >= 0 && ref.indexOf("R0, a R register") >= 0, ref;
	const dyn = refusal([raiserABC(RaiserOpcode.AddF64, 0, 1, 2)], [RaiserRegClass.Float, RaiserRegClass.Dyn, RaiserRegClass.Float]);
	assert dyn.indexOf("R1, a D register, where the opcode needs F") >= 0, dyn;
	const across = refusal([raiserABC(RaiserOpcode.Move, 0, 1, 0)], [RaiserRegClass.Float, RaiserRegClass.Word]);
	assert across.indexOf("copies R1 (W) to R0 (F) across register classes") >= 0, across;
}

test "a register named past the function's registers is refused" {
	assert refusal([raiserABC(RaiserOpcode.LoadNil, 255, 0, 0)], [RaiserRegClass.Dyn]).indexOf("names register R255 of 1") >= 0;
}

function frameField(op: RaiserOpcode, a: int32, b: int32, c: int32, kind: MemKind): RaiserInstruction {
	const inst = raiserABC(op, a, b, c);
	inst.slot = kind as int32;
	return inst;
}

test "frame byte fields accept Bool scalar registers" {
	const classes = [RaiserRegClass.Word, RaiserRegClass.Bool, RaiserRegClass.Bool];
	const load = refusal([frameField(RaiserOpcode.LoadFrame, 2, 0, 7, MemKind.U8)], classes);
	const store = refusal([frameField(RaiserOpcode.StoreFrame, 0, 7, 1, MemKind.U8)], classes);
	assert load == "", load;
	assert store == "", store;
}

test "frame byte fields retain Bool constraints during class inference" {
	let error = "";
	try {
		const layout = layoutRegisters("boolFields", [
			raiserABx(RaiserOpcode.LoadConst, 1, 0),
			raiserABx(RaiserOpcode.LoadConst, 2, 1),
			frameField(RaiserOpcode.StoreFrame, 0, 7, 1, MemKind.U8),
			frameField(RaiserOpcode.LoadFrame, 2, 0, 7, MemKind.U8),
		], [raiserBool(true), raiserBool(false)], 3, null);
		assert layout.regClasses[0] == RaiserRegClass.Word;
		assert layout.regClasses[1] == RaiserRegClass.Bool && layout.regClasses[2] == RaiserRegClass.Bool;
	} catch (e) { error = e.message; }
	assert error == "", error;
}

test "frame data infers every opaque Word and the widened scalar field classes" {
	const layout = layoutRegisters("packed", [
		raiserABC(RaiserOpcode.MoveN, 3, 0, 3),
		raiserABC(RaiserOpcode.ZeroN, 6, 2, 0),
		frameField(RaiserOpcode.LoadFrame, 8, 6, 12, MemKind.F32),
		frameField(RaiserOpcode.StoreFrame, 0, 16, 9, MemKind.F64),
		frameField(RaiserOpcode.LoadFrame, 10, 3, 8, MemKind.I16),
	], [], 11, null);
	for (let r = 0; r < 8; r += 1) {
		assert layout.regClasses[r] == RaiserRegClass.Word, `R${r}`;
	}
	assert layout.regClasses[8] == RaiserRegClass.Float;
	assert layout.regClasses[9] == RaiserRegClass.Float;
	assert layout.regClasses[10] == RaiserRegClass.Word;
	assert layout.code[0].a == 3 && layout.code[0].b == 0;
	assert layout.code[2].a == operandTagged(8, RaiserRegClass.Float);
	assert layout.code[2].b == 6 && layout.code[2].slot == (MemKind.F32 as int32);
}

test "frame data refuses nonpositive counts and either span past the frame" {
	const words = [RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Word];
	assert refusal([raiserABC(RaiserOpcode.MoveN, 0, 1, 0)], words).includes("positive Word count");
	assert refusal([raiserABC(RaiserOpcode.ZeroN, 0, 0, 0)], words).includes("positive Word count");
	assert refusal([raiserABC(RaiserOpcode.ZeroN, 0, -1, 0)], words).includes("packed operand");
	assert refusal([raiserABC(RaiserOpcode.MoveN, 2, 0, 2)], words).includes("past the frame");
	assert refusal([raiserABC(RaiserOpcode.MoveN, 0, 2, 2)], words).includes("past the frame");
	assert refusal([raiserABC(RaiserOpcode.ZeroN, 1, 3, 0)], words).includes("past the frame");
	assert refusal([frameField(RaiserOpcode.LoadFrame, 0, 2, 8, MemKind.I8)], words).includes("past the frame");
	assert refusal([frameField(RaiserOpcode.StoreFrame, 2, 8, 0, MemKind.I8)], words).includes("past the frame");
}

test "frame data refuses any non-Word slot in a raw span including skipped field prefixes" {
	const word = RaiserRegClass.Word;
	for (const other of [RaiserRegClass.Ref, RaiserRegClass.Dyn, RaiserRegClass.Float, RaiserRegClass.Bool]) {
		const classes = [word, other, word, word, word, word];
		assert refusal([raiserABC(RaiserOpcode.MoveN, 3, 0, 3)], classes).includes("R1 is not opaque Word storage");
		assert refusal([raiserABC(RaiserOpcode.MoveN, 0, 3, 3)], classes).includes("R1 is not opaque Word storage");
		assert refusal([raiserABC(RaiserOpcode.ZeroN, 0, 3, 0)], classes).includes("R1 is not opaque Word storage");
		assert refusal([frameField(RaiserOpcode.LoadFrame, 5, 0, 16, MemKind.I64)], classes).includes("R1 is not opaque Word storage");
		assert refusal([frameField(RaiserOpcode.StoreFrame, 0, 16, 5, MemKind.I64)], classes).includes("R1 is not opaque Word storage");
	}
}

test "frame fields refuse invalid kinds incompatible scalar classes and unaligned byte offsets" {
	const words = [RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Word];
	for (const kind of [0, -1, 255, 1.5, 0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0]) {
		const load = frameField(RaiserOpcode.LoadFrame, 2, 0, 0, MemKind.I8);
		const store = frameField(RaiserOpcode.StoreFrame, 0, 0, 2, MemKind.I8);
		load.slot = kind;
		store.slot = kind;
		assert refusal([load], words).includes("invalid scalar MemKind");
		assert refusal([store], words).includes("invalid scalar MemKind");
	}
	for (const kind of [MemKind.I16, MemKind.U32, MemKind.F32, MemKind.F64]) {
		assert refusal([frameField(RaiserOpcode.LoadFrame, 2, 0, 1, kind)], words).includes("unaligned byte offset");
		assert refusal([frameField(RaiserOpcode.StoreFrame, 0, 1, 2, kind)], words).includes("unaligned byte offset");
	}
	assert refusal([frameField(RaiserOpcode.LoadFrame, 2, 0, 0, MemKind.F32)], words).includes("incompatible scalar class");
	assert refusal([frameField(RaiserOpcode.StoreFrame, 0, 0, 2, MemKind.F64)], words).includes("incompatible scalar class");
	for (const other of [RaiserRegClass.Ref, RaiserRegClass.Dyn, RaiserRegClass.Float, RaiserRegClass.Bool]) {
		assert refusal([frameField(RaiserOpcode.LoadFrame, 2, 0, 0, MemKind.I8)], [words[0], words[1], other]).includes("incompatible scalar class");
	}
}

test "a frame field alone infers every Word from its base through its byte extent" {
	for (const op of [RaiserOpcode.LoadFrame, RaiserOpcode.StoreFrame]) {
		const field = op == RaiserOpcode.LoadFrame
			? frameField(op, 3, 0, 16, MemKind.F32)
			: frameField(op, 0, 16, 3, MemKind.F32);
		const layout = layoutRegisters("fieldOnly", [field], [], 4, null);
		for (let r = 0; r < 3; r += 1) {
			assert layout.regClasses[r] == RaiserRegClass.Word, `R${r}`;
		}
		assert layout.regClasses[3] == RaiserRegClass.Float;
	}
}

test "inference refuses a reference use inside an opaque Word span" {
	const word = RaiserRegClass.Word;
	const classes = [word, word, word, word, word, word];
	for (const field of [
		raiserABC(RaiserOpcode.MoveN, 3, 0, 3),
		raiserABC(RaiserOpcode.ZeroN, 0, 3, 0),
		frameField(RaiserOpcode.LoadFrame, 5, 0, 16, MemKind.I64),
		frameField(RaiserOpcode.StoreFrame, 0, 16, 5, MemKind.I64),
	]) {
		const error = refusal([
			field, raiserABC(RaiserOpcode.NewObject, 1, 0, 0),
		], classes, true);
		assert error.includes("R1 of probe is used as classes"), error;
	}
}

test "frame data refuses fractional and oversized operands before narrowing" {
	const words = [RaiserRegClass.Word, RaiserRegClass.Word];
	for (const value of [0.5, 65536, 4294967296, 0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0]) {
		for (const inferred of [false, true]) {
			assert refusal([
				raiserABC(RaiserOpcode.MoveN, value, 0, 1),
			], words, inferred).includes("invalid packed operand");
			assert refusal([
				raiserABC(RaiserOpcode.ZeroN, 0, value, 0),
			], words, inferred).includes("invalid packed operand");
			const field = frameField(RaiserOpcode.LoadFrame, 1, 0, 0, MemKind.I8);
			field.c = value;
			assert refusal([field], words, inferred).includes("invalid packed operand");
		}
	}
}
