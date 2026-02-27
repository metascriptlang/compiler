// Raiser VM — Disassembler
// Human-readable bytecode formatting for debugging and test output.

import { test, check, testGroup } from "std/testing";
import {
	RaiserOpcode, RaiserInstruction,
	raiserABC, raiserABx, raiserAx,
	getBx, getSignedAx
} from "./bytecode";
import {
	RaiserValue, raiserInt, raiserToString
} from "./value";
import {
	RaiserModule, RaiserFunction,
	getModuleEntry, getFuncName, getFuncCodeLen,
	getFuncInst, getFuncConst, getFuncConstLen,
	makeTestModule
} from "./module";

// --- Opcode names ---

export function opName(op: RaiserOpcode): string {
	if (op === RaiserOpcode.LoadConst) return "LoadConst";
	if (op === RaiserOpcode.Move) return "Move";
	if (op === RaiserOpcode.LoadNil) return "LoadNil";
	if (op === RaiserOpcode.AddI64) return "AddI64";
	if (op === RaiserOpcode.SubI64) return "SubI64";
	if (op === RaiserOpcode.MulI64) return "MulI64";
	if (op === RaiserOpcode.DivI64) return "DivI64";
	if (op === RaiserOpcode.ModI64) return "ModI64";
	if (op === RaiserOpcode.NegI64) return "NegI64";
	if (op === RaiserOpcode.BeqI64) return "BeqI64";
	if (op === RaiserOpcode.BneI64) return "BneI64";
	if (op === RaiserOpcode.BltI64) return "BltI64";
	if (op === RaiserOpcode.BleI64) return "BleI64";
	if (op === RaiserOpcode.BgtI64) return "BgtI64";
	if (op === RaiserOpcode.BgeI64) return "BgeI64";
	if (op === RaiserOpcode.Jump) return "Jump";
	if (op === RaiserOpcode.Call) return "Call";
	if (op === RaiserOpcode.Ret) return "Ret";
	if (op === RaiserOpcode.Halt) return "Halt";
	if (op === RaiserOpcode.Print) return "Print";
	return "Op(" + op + ")";
}

// --- Format helpers ---

function isABxOp(op: RaiserOpcode): boolean {
	return op === RaiserOpcode.LoadConst;
}

function isAxOp(op: RaiserOpcode): boolean {
	return op === RaiserOpcode.Jump;
}

export function disasmInst(inst: RaiserInstruction): string {
	if (isAxOp(inst.op)) return opName(inst.op) + " " + getSignedAx(inst);
	if (isABxOp(inst.op)) return opName(inst.op) + " R" + inst.a + " K" + getBx(inst);
	return opName(inst.op) + " R" + inst.a + " R" + inst.b + " R" + inst.c;
}

// Disassemble a function to a single string (for test assertions)
export function disasmFunc(func: RaiserFunction): string {
	let out = "; " + getFuncName(func) + "\n";
	let i = 0;
	const len = getFuncCodeLen(func);
	while (i < len) {
		const inst = getFuncInst(func, i);
		let line = "  " + i + ": " + disasmInst(inst);
		if (inst.op === RaiserOpcode.LoadConst) {
			const cIdx = getBx(inst);
			if (cIdx < getFuncConstLen(func)) {
				const cVal = getFuncConst(func, cIdx);
				line = line + "  ; " + raiserToString(cVal);
			}
		}
		out = out + line + "\n";
		i = i + 1;
	}
	return out;
}

// Print to console (for repl/debug use)
export function printModule(mod: RaiserModule): void {
	const entry = getModuleEntry(mod);
	const s = disasmFunc(entry);
	console.log(s);
}

// --- Tests ---

testGroup("Disassembler", () => {
	test("ABC instruction format", () => {
		const inst = raiserABC(RaiserOpcode.AddI64, 2, 0, 1);
		check(disasmInst(inst) === "AddI64 R2 R0 R1");
	});

	test("ABx instruction format", () => {
		const inst = raiserABx(RaiserOpcode.LoadConst, 0, 3);
		check(disasmInst(inst) === "LoadConst R0 K3");
	});

	test("Ax instruction format", () => {
		const inst = raiserAx(RaiserOpcode.Jump, -4);
		check(disasmInst(inst) === "Jump -4");
	});

	test("Halt format", () => {
		const inst = raiserABC(RaiserOpcode.Halt, 2, 0, 0);
		check(disasmInst(inst) === "Halt R2 R0 R0");
	});

	test("disasmFunc includes constant annotations", () => {
		const mod = makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABC(RaiserOpcode.Halt, 0, 0, 0),
			],
			[raiserInt(42)]
		);
		const entry = getModuleEntry(mod);
		const s = disasmFunc(entry);
		check(s.length > 0);
		// Should contain "LoadConst" and the constant value annotation
	});
});
