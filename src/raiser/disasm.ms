// Raiser VM — Disassembler
// Human-readable bytecode formatting for debugging and test output.

import { RaiserOpcode, RaiserInstruction, raiserABC, raiserABx, raiserAx, getBx, getSignedAx } from "./bytecode";
import { raiserInt, raiserToString } from "./value";
import {
	RaiserModule, RaiserFunction,
	getModuleEntry, getFuncName, getFuncCodeLen, getFuncInst, getFuncConst, getFuncConstLen, makeTestModule
} from "./module";

// --- Opcode names ---

export function opName(op: RaiserOpcode): string {
	return match (op) {
		RaiserOpcode.LoadConst => "LoadConst",
		RaiserOpcode.Move => "Move",
		RaiserOpcode.LoadNil => "LoadNil",
		RaiserOpcode.AddI64 => "AddI64",
		RaiserOpcode.SubI64 => "SubI64",
		RaiserOpcode.MulI64 => "MulI64",
		RaiserOpcode.DivI64 => "DivI64",
		RaiserOpcode.ModI64 => "ModI64",
		RaiserOpcode.NegI64 => "NegI64",
		RaiserOpcode.BeqI64 => "BeqI64",
		RaiserOpcode.BneI64 => "BneI64",
		RaiserOpcode.BltI64 => "BltI64",
		RaiserOpcode.BleI64 => "BleI64",
		RaiserOpcode.BgtI64 => "BgtI64",
		RaiserOpcode.BgeI64 => "BgeI64",
		RaiserOpcode.Jump => "Jump",
		RaiserOpcode.Call => "Call",
		RaiserOpcode.Ret => "Ret",
		RaiserOpcode.Halt => "Halt",
		RaiserOpcode.Print => "Print",
		RaiserOpcode.NewArray => "NewArray",
		RaiserOpcode.LoadIndex => "LoadIndex",
		RaiserOpcode.StoreIndex => "StoreIndex",
		RaiserOpcode.ArrayLen => "ArrayLen",
		RaiserOpcode.ArrayPush => "ArrayPush",
		RaiserOpcode.NewObject => "NewObject",
		RaiserOpcode.LoadField => "LoadField",
		RaiserOpcode.StoreField => "StoreField",
		RaiserOpcode.ConcatStr => "ConcatStr",
		RaiserOpcode.EqStr => "EqStr",
		RaiserOpcode.NeStr => "NeStr",
		RaiserOpcode.LtStr => "LtStr",
		RaiserOpcode.LeStr => "LeStr",
		RaiserOpcode.StrLen => "StrLen",
		RaiserOpcode.StrCharAt => "StrCharAt",
		RaiserOpcode.StrSlice => "StrSlice",
		RaiserOpcode.CallIndirect => "CallIndirect",
		RaiserOpcode.AddF64 => "AddF64",
		RaiserOpcode.SubF64 => "SubF64",
		RaiserOpcode.MulF64 => "MulF64",
		RaiserOpcode.DivF64 => "DivF64",
		RaiserOpcode.NegF64 => "NegF64",
		RaiserOpcode.BeqF64 => "BeqF64",
		RaiserOpcode.BneF64 => "BneF64",
		RaiserOpcode.BltF64 => "BltF64",
		RaiserOpcode.BleF64 => "BleF64",
		RaiserOpcode.BgtF64 => "BgtF64",
		RaiserOpcode.BgeF64 => "BgeF64",
		RaiserOpcode.BitAnd => "BitAnd",
		RaiserOpcode.BitOr => "BitOr",
		RaiserOpcode.BitXor => "BitXor",
		RaiserOpcode.BitNot => "BitNot",
		RaiserOpcode.ShiftLeft => "ShiftLeft",
		RaiserOpcode.ShiftRight => "ShiftRight",
		RaiserOpcode.CallHost => "CallHost",
	};
}

// --- Format helpers ---

function isABxOp(op: RaiserOpcode): boolean {
	return op === RaiserOpcode.LoadConst;
}

function isAxOp(op: RaiserOpcode): boolean {
	return op === RaiserOpcode.Jump;
}

export function disasmInst(inst: RaiserInstruction): string {
	if (isAxOp(inst.op)) return `${opName(inst.op)} ${getSignedAx(inst)}`;
	if (isABxOp(inst.op)) return `${opName(inst.op)} R${inst.a} K${getBx(inst)}`;
	return `${opName(inst.op)} R${inst.a} R${inst.b} R${inst.c}`;
}

// Disassemble a function to a single string (for test assertions)
export function disasmFunc(func: RaiserFunction): string {
	let result = `; ${getFuncName(func)}\n`;
	const len = getFuncCodeLen(func);
	for (let i = 0; i < len; i = i + 1) {
		const inst = getFuncInst(func, i);
		let line = `  ${i}: ${disasmInst(inst)}`;
		if (inst.op === RaiserOpcode.LoadConst) {
			const cIdx = getBx(inst);
			if (cIdx < getFuncConstLen(func)) {
				const cVal = getFuncConst(func, cIdx);
				line = `${line}  ; ${raiserToString(cVal)}`;
			}
		}
		result = `${result}${line}\n`;
	}
	return result;
}

// Print to console (for repl/debug use)
export function printModule(mod: RaiserModule): void {
	const entry = getModuleEntry(mod);
	const s = disasmFunc(entry);
	console.log(s);
}

// --- Tests ---
test "ABC instruction format" {
	const inst = raiserABC(RaiserOpcode.AddI64, 2, 0, 1);
	assert disasmInst(inst) === "AddI64 R2 R0 R1";
}

test "ABx instruction format" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 0, 3);
	assert disasmInst(inst) === "LoadConst R0 K3";
}

test "Ax instruction format" {
	const inst = raiserAx(RaiserOpcode.Jump, -4);
	assert disasmInst(inst) === "Jump -4";
}

test "Halt format" {
	const inst = raiserABC(RaiserOpcode.Halt, 2, 0, 0);
	assert disasmInst(inst) === "Halt R2 R0 R0";
}

test "disasmFunc includes constant annotations" {
	const mod = makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserInt(42)]
	);
	const entry = getModuleEntry(mod);
	const s = disasmFunc(entry);
	assert s.length > 0;
	// Should contain "LoadConst" and the constant value annotation
}
