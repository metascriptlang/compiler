// Raiser VM — Bytecode executor
// Computed goto dispatch via dispatch.c, if/else fallback for Print.

@include("dispatch.h")
import { raiser_dispatch_impl } from "./dispatch.h";

import { test, check, testGroup } from "std/testing";
import {
	RaiserOpcode, RaiserInstruction,
	raiserABC, raiserABx, raiserAx,
	getBx, getSignedBx, getSignedAx
} from "./bytecode";
import {
	RaiserValue, RaiserValueKind,
	raiserNil, raiserInt, raiserToInt, raiserToBool, raiserToString, raiserIsNil
} from "./value";
import {
	RaiserModule, RaiserFunction,
	makeTestModule, getModuleEntry, getModuleFunc,
	getFuncCodeLen, getFuncInst, getFuncConst
} from "./module";

// --- VM State ---

export interface RaiserRegFile {
	slots: RaiserValue[];
}

export interface RaiserVM {
	mod: RaiserModule;
	regs: RaiserRegFile;
	ip: number;
	halted: boolean;
	exitValue: RaiserValue;
	output: string;
}

export function createVM(mod: RaiserModule): RaiserVM {
	const slots: RaiserValue[] = [];
	let i = 0;
	while (i < 256) {
		const nil = raiserNil();
		slots.push(nil);
		i = i + 1;
	}
	const regs: RaiserRegFile = { slots };
	const nilVal = raiserNil();
	return { mod, regs, ip: 0, halted: false, exitValue: nilVal, output: "" };
}

// --- Register access via helper functions (DRC-safe) ---

function getReg(vm: RaiserVM, idx: number): RaiserValue {
	return vm.regs.slots[idx];
}

function setReg(vm: RaiserVM, idx: number, val: RaiserValue): void {
	vm.regs.slots[idx] = val;
}

// --- Execute ---

export function execModule(mod: RaiserModule): RaiserVM {
	const vm = createVM(mod);
	const entry = getModuleEntry(mod);

	while (!vm.halted) {
		const status = raiser_dispatch_impl(vm);
		if (status === 0) break;

		// C dispatch returned 1.0 — handle Print in MetaScript
		const inst = getFuncInst(entry, vm.ip);
		vm.ip = vm.ip + 1;

		if (inst.op === RaiserOpcode.Print) {
			const val = getReg(vm, inst.a);
			const s = raiserToString(val);
			vm.output = vm.output + s + "\n";
		} else {
			vm.halted = true;
		}
	}

	return vm;
}

// --- Tests ---

testGroup("VM execute", () => {
	test("halt returns constant", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABC(RaiserOpcode.Halt, 0, 0, 0),
			],
			[raiserInt(42)]
		));
		check(vm.exitValue.intVal === 42);
	});

	test("add: 10 + 20 = 30", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 1),
				raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			],
			[raiserInt(10), raiserInt(20)]
		));
		check(vm.exitValue.intVal === 30);
	});

	test("sub: 100 - 42 = 58", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 1),
				raiserABC(RaiserOpcode.SubI64, 2, 0, 1),
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			],
			[raiserInt(100), raiserInt(42)]
		));
		check(vm.exitValue.intVal === 58);
	});

	test("mul: 6 * 7 = 42", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 1),
				raiserABC(RaiserOpcode.MulI64, 2, 0, 1),
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			],
			[raiserInt(6), raiserInt(7)]
		));
		check(vm.exitValue.intVal === 42);
	});

	test("div: 84 / 2 = 42", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 1),
				raiserABC(RaiserOpcode.DivI64, 2, 0, 1),
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			],
			[raiserInt(84), raiserInt(2)]
		));
		check(vm.exitValue.intVal === 42);
	});

	test("mod: 17 % 5 = 2", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 1),
				raiserABC(RaiserOpcode.ModI64, 2, 0, 1),
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			],
			[raiserInt(17), raiserInt(5)]
		));
		check(vm.exitValue.intVal === 2);
	});

	test("neg: -(7) = -7", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABC(RaiserOpcode.NegI64, 1, 0, 0),
				raiserABC(RaiserOpcode.Halt, 1, 0, 0),
			],
			[raiserInt(7)]
		));
		check(vm.exitValue.intVal === -7);
	});

	test("chained: (2 + 3) * 4 = 20", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 1),
				raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
				raiserABx(RaiserOpcode.LoadConst, 3, 2),
				raiserABC(RaiserOpcode.MulI64, 4, 2, 3),
				raiserABC(RaiserOpcode.Halt, 4, 0, 0),
			],
			[raiserInt(2), raiserInt(3), raiserInt(4)]
		));
		check(vm.exitValue.intVal === 20);
	});

	test("print captures output", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABC(RaiserOpcode.Print, 0, 0, 0),
				raiserABC(RaiserOpcode.Halt, 0, 0, 0),
			],
			[raiserInt(42)]
		));
		check(vm.output === "42\n");
	});
});

testGroup("VM branches", () => {
	test("bgt: 10 > 5 → true branch", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),     // R0 = 10
				raiserABx(RaiserOpcode.LoadConst, 1, 1),     // R1 = 5
				raiserABC(RaiserOpcode.BgtI64, 0, 1, 1),     // if R0 > R1 skip 1
				raiserAx(RaiserOpcode.Jump, 2),               // else jump +2
				raiserABx(RaiserOpcode.LoadConst, 2, 2),     // true: R2 = 1
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 2, 3),     // false: R2 = 0
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			],
			[raiserInt(10), raiserInt(5), raiserInt(1), raiserInt(0)]
		));
		check(vm.exitValue.intVal === 1);
	});

	test("bgt: 3 > 5 → false branch", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 1),
				raiserABC(RaiserOpcode.BgtI64, 0, 1, 1),
				raiserAx(RaiserOpcode.Jump, 2),
				raiserABx(RaiserOpcode.LoadConst, 2, 2),
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 2, 3),
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			],
			[raiserInt(3), raiserInt(5), raiserInt(1), raiserInt(0)]
		));
		check(vm.exitValue.intVal === 0);
	});

	test("loop: sum 1..5 = 15", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),     // 0: R0 = 0 (sum)
				raiserABx(RaiserOpcode.LoadConst, 1, 1),     // 1: R1 = 1 (i)
				raiserABx(RaiserOpcode.LoadConst, 2, 2),     // 2: R2 = 5 (limit)
				raiserABx(RaiserOpcode.LoadConst, 3, 1),     // 3: R3 = 1 (incr)
				raiserABC(RaiserOpcode.BgtI64, 1, 2, 3),     // 4: if i > limit skip 3 → halt
				raiserABC(RaiserOpcode.AddI64, 0, 0, 1),     // 5: sum += i
				raiserABC(RaiserOpcode.AddI64, 1, 1, 3),     // 6: i += 1
				raiserAx(RaiserOpcode.Jump, -4),              // 7: back to cmp (ip=8-4=4)
				raiserABC(RaiserOpcode.Halt, 0, 0, 0),       // 8: halt
			],
			[raiserInt(0), raiserInt(1), raiserInt(5)]
		));
		check(vm.exitValue.intVal === 15);
	});

	test("beq: equal values", () => {
		const vm = execModule(makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 0),
				raiserABC(RaiserOpcode.BeqI64, 0, 1, 1),     // if R0 == R1 skip 1
				raiserAx(RaiserOpcode.Jump, 1),
				raiserABx(RaiserOpcode.LoadConst, 2, 1),     // R2 = 1 (equal)
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			],
			[raiserInt(7), raiserInt(1)]
		));
		check(vm.exitValue.intVal === 1);
	});
});
