// Phase 1 spike — untagged register VM (i64 hot path only)
//
// Architectural prototype to measure how much speedup the typed-bytecode
// optimization plan unlocks vs the current boxed VM (../vm.ms).
//
// Three differences from vm.ms:
//   1. Register file is `number[]` (untagged i64 slot) instead of
//      `RaiserValue[]` (33-byte heap struct + pointer indirection).
//   2. Arithmetic ops write directly to the slot — no per-op heap alloc
//      via raiserInt(). Hot loop becomes alloc-free.
//   3. Constants are pre-extracted into number[] before dispatch begins,
//      so the steady-state loop never touches RaiserValue.
//
// Scope: only opcodes needed for iterative numeric benchmarks. Object/
// array/string/call/ret are intentionally absent — this is a spike, not
// a production replacement.
//
// Run via spike/bench.ms which compares vm.ms vs this on hand-built
// bytecode for sum(1..N) and iterative Fibonacci.

import {
	RaiserOpcode, RaiserInstruction, getSignedAx, getBx,
} from "../bytecode";
import {
	RaiserModule, getModuleEntry,
} from "../module";

// --- VM state ---

export interface FastVM {
	code: RaiserInstruction[];
	constants: number[];      // pre-extracted i64 values
	regs: number[];           // 256 untagged i64 slots
	ip: number;
	halted: boolean;
	exitValue: number;
	opCount: number;
	error: string;
}

// --- Execute ---

export function execFastModule(mod: RaiserModule): number {
	const entry = getModuleEntry(mod);

	// Pre-extract constants from RaiserValue[] → flat number[].
	// One-time cost outside the hot loop.
	const constants: number[] = [];
	for (const c of entry.constants) {
		constants.push(c.intVal);
	}

	// Untagged register file. 256 slots is enough for spike workloads.
	const regs: number[] = [];
	for (let i = 0; i < 256; i = i + 1) {
		regs.push(0);
	}

	let ip = 0;
	let halted = false;
	let exitValue = 0;
	let opCount = 0;
	const opLimit = 100000000;
	const code = entry.code;

	while (!halted) {
		opCount = opCount + 1;
		if (opCount > opLimit) {
			halted = true;
			break;
		}

		const inst = code[ip];
		ip = ip + 1;
		const op = inst.op;

		if (op === RaiserOpcode.LoadConst) {
			const bx = getBx(inst);
			regs[inst.a] = constants[bx];
		} else if (op === RaiserOpcode.Move) {
			regs[inst.a] = regs[inst.b];
		} else if (op === RaiserOpcode.LoadNil) {
			regs[inst.a] = 0;
		} else if (op === RaiserOpcode.AddI64) {
			regs[inst.a] = regs[inst.b] + regs[inst.c];
		} else if (op === RaiserOpcode.SubI64) {
			regs[inst.a] = regs[inst.b] - regs[inst.c];
		} else if (op === RaiserOpcode.MulI64) {
			regs[inst.a] = regs[inst.b] * regs[inst.c];
		} else if (op === RaiserOpcode.NegI64) {
			regs[inst.a] = -regs[inst.b];
		} else if (op === RaiserOpcode.BeqI64) {
			if (regs[inst.a] === regs[inst.b]) ip = ip + inst.c;
		} else if (op === RaiserOpcode.BneI64) {
			if (regs[inst.a] !== regs[inst.b]) ip = ip + inst.c;
		} else if (op === RaiserOpcode.BltI64) {
			if (regs[inst.a] < regs[inst.b]) ip = ip + inst.c;
		} else if (op === RaiserOpcode.BleI64) {
			if (regs[inst.a] <= regs[inst.b]) ip = ip + inst.c;
		} else if (op === RaiserOpcode.BgtI64) {
			if (regs[inst.a] > regs[inst.b]) ip = ip + inst.c;
		} else if (op === RaiserOpcode.BgeI64) {
			if (regs[inst.a] >= regs[inst.b]) ip = ip + inst.c;
		} else if (op === RaiserOpcode.Jump) {
			const offset = getSignedAx(inst);
			ip = ip + offset;
		} else if (op === RaiserOpcode.Halt) {
			halted = true;
			exitValue = regs[inst.a];
		} else {
			halted = true;
		}
	}

	return exitValue;
}
