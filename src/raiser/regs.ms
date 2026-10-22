// Raiser VM — register layout: class inference for hand-built code, the operand verifier and the renumbering
// from one number per register to a rank in the word file or the ref file.

import {
	RaiserOpcode, RaiserInstruction, RaiserRegClass, RaiserRole, RaiserConvClass, regClassLetter, inRefFile, operandTagged,
	opRole, opHasSite, siteArgCount, convTarget, raiserABC
} from "./bytecode";
import { RaiserValue, RaiserValueKind } from "./value";

const MAX_TAGGED_RANK: int32 = 8191;
const MAX_FIELD: int32 = 65535;
const MAX_SIG_ARGS: int32 = 20;
const SITE_HEADER: int32 = 4;

export interface RaiserRegLayout {
	code: RaiserInstruction[];
	regClasses: RaiserRegClass[];
	regOps: int32[];       // the tagged operand of each input register
	wordRegs: int32;
	refRegs: int32;
	blocks: int64[];       // per site: word start, ref start, argument count, class signature, then one tagged operand per argument
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
	const mask: int32[] = [];
	for (let r = 0; r < regCount; r += 1) mask.push(CLASS_ALL);
	let changed = true;
	while (changed) {
		changed = false;
		for (const inst of code) {
			const op = inst.op;
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
	const wordsBefore: int32[] = [];
	const refsBefore: int32[] = [];
	const regOps: int32[] = [];
	let words: int32 = 0;
	let refs: int32 = 0;
	for (let r = 0; r < regCount; r += 1) {
		wordsBefore.push(words);
		refsBefore.push(refs);
		const rank = inRefFile(classes[r]) ? refs : words;
		regOps.push(operandTagged(rank, classes[r]));
		if (inRefFile(classes[r])) refs += 1; else words += 1;
	}
	wordsBefore.push(words);
	refsBefore.push(refs);
	const out: RaiserInstruction[] = [];
	const blocks: int64[] = [];
	for (let pc = 0; pc < code.length; pc += 1) {
		const inst = code[pc];
		let op = inst.op;
		if (op == RaiserOpcode.Move) {
			const ca = inst.a < regCount ? classes[inst.a as int32] : RaiserRegClass.Dyn;
			const cb = inst.b < regCount ? classes[inst.b as int32] : RaiserRegClass.Dyn;
			if (inst.a >= regCount || inst.b >= regCount || ca != cb) throw new Error(`internal: Move at instruction ${pc} of ${name} copies R${inst.b} (${inst.b < regCount ? regClassLetter(cb) : "none"}) to R${inst.a} (${inst.a < regCount ? regClassLetter(ca) : "none"}) across register classes`);
			op = inRefFile(ca) ? RaiserOpcode.MoveR : RaiserOpcode.MoveW;
		}
		if (op == RaiserOpcode.LoadSlot && inst.a < regCount) op = typedSlot(op, classes[inst.a as int32]);
		if (op == RaiserOpcode.StoreSlot && inst.c < regCount) op = typedSlot(op, classes[inst.c as int32]);
		if (inst.a < regCount && (op == RaiserOpcode.BeqI64 || op == RaiserOpcode.BneI64 || op == RaiserOpcode.BrEqI64 || op == RaiserOpcode.BrNeI64)) op = ranked(op, classes[inst.a as int32]);
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
		if (op == RaiserOpcode.LoadConst) {
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
			blocks.push(wordsBefore[first] as int64);
			blocks.push(refsBefore[first] as int64);
			blocks.push(argc as int64);
			blocks.push(signatureOf(classes, first, argc));
			for (let i = 0; i < argc; i += 1) blocks.push(regOps[first + i] as int64);
		}
		const result = raiserABC(op, fields[0], fields[1], c);
		result.line = inst.line;
		result.slot = inst.slot;
		out.push(result);
	}
	const sigs: int64[] = [];
	const sigLimit = regCount < MAX_SIG_ARGS ? regCount : MAX_SIG_ARGS;
	for (let n = 0; n <= sigLimit; n += 1) sigs.push(signatureOf(classes, 0, n));
	return { code: out, regClasses: classes, regOps, wordRegs: words, refRegs: refs, blocks, sigs };
}

function refusal(code: RaiserInstruction[], classes: RaiserRegClass[]): string {
	try {
		layoutRegisters("probe", code, [], classes.length, classes);
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
