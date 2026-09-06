// Phase 1d spike — packed instruction stream on top of Phase 1a.
//
// Combines:
//   - Phase 1a: untagged register file (number[] slots, no boxing)
//   - Phase 1d: each instruction packed into a single number (int32 bits)
//
// Encoding (matches Lua-style ABC/ABx/Ax):
//   ABC:  [op:8][a:8][b:8][c:8]
//   ABx:  [op:8][a:8][bx:16]      bx = (b << 8) | c at decode
//   Ax:   [op:8][ax:24]           ax sign-extended from low 24 bits
//
// Why this should be faster than vmFast.ms:
//   1. Code stream is number[] (8 bytes/inst) vs RaiserInstruction[]
//      where each element is a heap struct pointer (~40 bytes incl pointer).
//      ~5× memory reduction → fewer L1 cache misses on hot dispatch.
//   2. One memory load per instruction vs four field loads
//      (inst.op, inst.a, inst.b, inst.c) through a struct pointer.
//   3. Decode (shift + mask) is register-to-register — much cheaper than
//      pointer-chase load.
//
// Scope: i64 hot path only, same as vmFast. Object/array/string/call absent.

import { RaiserOpcode, RaiserInstruction } from "../bytecode";
import { RaiserModule, getModuleEntry } from "../module";

// One-time pack: RaiserInstruction[] → number[] (each is packed int32).
// Done outside hot loop so its cost is amortized.
export function packCode(insts: RaiserInstruction[]): number[] {
	const out: number[] = [];
	for (const inst of insts) {
		const op: int32 = inst.op as int32;
		const a: int32 = inst.a as int32;
		const b: int32 = inst.b as int32;
		const c: int32 = inst.c as int32;
		const packed: int32 = ((op & 0xff) << 24) | ((a & 0xff) << 16) | ((b & 0xff) << 8) | (c & 0xff);
		out.push(packed as number);
	}
	return out;
}

export function execPackedModule(mod: RaiserModule): number {
	const entry = getModuleEntry(mod);

	// Pre-extract constants (i64 values).
	const constants: number[] = [];
	for (const c of entry.constants) {
		constants.push(c.intVal);
	}

	// Pack code.
	const code = packCode(entry.code);

	// Untagged register file.
	const regs: number[] = [];
	for (let i = 0; i < 256; i = i + 1) regs.push(0);

	let ip = 0;
	let halted = false;
	let exitValue = 0;
	let opCount = 0;
	const opLimit = 100000000;

	while (!halted) {
		opCount = opCount + 1;
		if (opCount > opLimit) {
			halted = true;
			break;
		}

		const packed: int32 = code[ip] as int32;
		ip = ip + 1;

		const op: int32 = (packed >> 24) & 0xff;
		const a: int32 = (packed >> 16) & 0xff;
		const b: int32 = (packed >> 8) & 0xff;
		const c: int32 = packed & 0xff;

		if (op as number == RaiserOpcode.LoadConst) {
			const bx: int32 = (b << 8) | c;
			regs[a as number] = constants[bx as number];
		} else if (op as number == RaiserOpcode.Move) {
			regs[a as number] = regs[b as number];
		} else if (op as number == RaiserOpcode.LoadNil) {
			regs[a as number] = 0;
		} else if (op as number == RaiserOpcode.AddI64) {
			regs[a as number] = regs[b as number] + regs[c as number];
		} else if (op as number == RaiserOpcode.SubI64) {
			regs[a as number] = regs[b as number] - regs[c as number];
		} else if (op as number == RaiserOpcode.MulI64) {
			regs[a as number] = regs[b as number] * regs[c as number];
		} else if (op as number == RaiserOpcode.NegI64) {
			regs[a as number] = -regs[b as number];
		} else if (op as number == RaiserOpcode.BeqI64) {
			if (regs[a as number] == regs[b as number]) ip = ip + (c as number);
		} else if (op as number == RaiserOpcode.BneI64) {
			if (regs[a as number] != regs[b as number]) ip = ip + (c as number);
		} else if (op as number == RaiserOpcode.BltI64) {
			if (regs[a as number] < regs[b as number]) ip = ip + (c as number);
		} else if (op as number == RaiserOpcode.BleI64) {
			if (regs[a as number] <= regs[b as number]) ip = ip + (c as number);
		} else if (op as number == RaiserOpcode.BgtI64) {
			if (regs[a as number] > regs[b as number]) ip = ip + (c as number);
		} else if (op as number == RaiserOpcode.BgeI64) {
			if (regs[a as number] >= regs[b as number]) ip = ip + (c as number);
		} else if (op as number == RaiserOpcode.Jump) {
			// Sign-extend low 24 bits.
			let ax: int32 = packed & 0xffffff;
			if ((ax as number) >= 8388608) ax = ax - 16777216;
			ip = ip + (ax as number);
		} else if (op as number == RaiserOpcode.Halt) {
			halted = true;
			exitValue = regs[a as number];
		} else {
			halted = true;
		}
	}

	return exitValue;
}
