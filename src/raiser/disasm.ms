// Raiser VM — Disassembler
// Human-readable bytecode formatting for debugging and test output.

import { RaiserOpcode, RaiserInstruction, RaiserRegClass, regClassLetter, operandTagged, operandKind, operandRank, operandClass, OPERAND_TAGGED, raiserABC, raiserABx, raiserAx, getBx, getSignedAx, immField, immValue, isBranchI64, branchField, branchOffset } from "./bytecode";
import { raiserInt, raiserToString, createArrayHeap } from "./value";
import {
	RaiserModule, RaiserFunction,
	getModuleEntry, getFuncName, getFuncCodeLen, getFuncInst, getFuncConst, getFuncConstLen, makeTestModule
} from "./module";

// --- Opcode names ---

export function opName(op: RaiserOpcode): string {
	return match (op) {
		RaiserOpcode.LoadConst => "LoadConst",
		RaiserOpcode.Move => "Move",
		RaiserOpcode.MoveW => "MoveW",
		RaiserOpcode.MoveR => "MoveR",
		RaiserOpcode.BeqR => "BeqR",
		RaiserOpcode.BneR => "BneR",
		RaiserOpcode.BrEqR => "BrEqR",
		RaiserOpcode.BrNeR => "BrNeR",
		RaiserOpcode.CopyValue => "CopyValue",
		RaiserOpcode.LoadGlobal => "LoadGlobal",
		RaiserOpcode.StoreGlobal => "StoreGlobal",
		RaiserOpcode.StrByteLen => "StrByteLen",
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
		RaiserOpcode.CallDirect => "CallDirect",
		RaiserOpcode.ForLtI64 => "ForLtI64",
		RaiserOpcode.ForLtI64Imm => "ForLtI64Imm",
		RaiserOpcode.Ret => "Ret",
		RaiserOpcode.Halt => "Halt",
		RaiserOpcode.Print => "Print",
		RaiserOpcode.NewArray => "NewArray",
		RaiserOpcode.LoadIndex => "LoadIndex",
		RaiserOpcode.StoreIndex => "StoreIndex",
		RaiserOpcode.ArrayLen => "ArrayLen",
		RaiserOpcode.ArrayPush => "ArrayPush",
		RaiserOpcode.ArraySetLen => "ArraySetLen",
		RaiserOpcode.NewObject => "NewObject",
		RaiserOpcode.LoadField => "LoadField",
		RaiserOpcode.StoreField => "StoreField",
		RaiserOpcode.LoadSlot => "LoadSlot",
		RaiserOpcode.StoreSlot => "StoreSlot",
		RaiserOpcode.LoadSlotW => "LoadSlotW",
		RaiserOpcode.LoadSlotR => "LoadSlotR",
		RaiserOpcode.StoreSlotW => "StoreSlotW",
		RaiserOpcode.StoreSlotR => "StoreSlotR",
		RaiserOpcode.ConcatStr => "ConcatStr",
		RaiserOpcode.EqStr => "EqStr",
		RaiserOpcode.NeStr => "NeStr",
		RaiserOpcode.LtStr => "LtStr",
		RaiserOpcode.LeStr => "LeStr",
		RaiserOpcode.StrLen => "StrLen",
		RaiserOpcode.StrCharAt => "StrCharAt",
		RaiserOpcode.StrSlice => "StrSlice",
		RaiserOpcode.ArraySlice => "ArraySlice",
		RaiserOpcode.CallIndirect => "CallIndirect",
		RaiserOpcode.CallClosure => "CallClosure",
		RaiserOpcode.CallClosureTyped => "CallClosureTyped",
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
		RaiserOpcode.NarrowU => "NarrowU",
		RaiserOpcode.SignExtend => "SignExtend",
		RaiserOpcode.ShiftRightU => "ShiftRightU",
		RaiserOpcode.Conv => "Conv",
		RaiserOpcode.BltU64 => "BltU64",
		RaiserOpcode.BleU64 => "BleU64",
		RaiserOpcode.DivU64 => "DivU64",
		RaiserOpcode.ModU64 => "ModU64",
		RaiserOpcode.AddU64 => "AddU64",
		RaiserOpcode.SubU64 => "SubU64",
		RaiserOpcode.MulU64 => "MulU64",
		RaiserOpcode.AddrReg => "AddrReg",
		RaiserOpcode.AddrGlobal => "AddrGlobal",
		RaiserOpcode.AddrIndex => "AddrIndex",
		RaiserOpcode.AddrField => "AddrField",
		RaiserOpcode.LoadDeref => "LoadDeref",
		RaiserOpcode.StoreDeref => "StoreDeref",
		RaiserOpcode.SameLoc => "SameLoc",
		RaiserOpcode.InstanceOf => "InstanceOf",
		RaiserOpcode.ObjConv => "ObjConv",
		RaiserOpcode.BTruthy => "BTruthy",
		RaiserOpcode.NarrowS => "NarrowS",
		RaiserOpcode.CallHost => "CallHost",
		RaiserOpcode.IsKind => "IsKind",
		RaiserOpcode.Trap => "Trap",
		RaiserOpcode.Yield => "Yield",
		RaiserOpcode.Spawn => "Spawn",
		RaiserOpcode.Await => "Await",
		RaiserOpcode.Sleep => "Sleep",
		RaiserOpcode.ModuleImport => "ModuleImport",
		RaiserOpcode.FutureNew => "FutureNew",
		RaiserOpcode.FutureSettle => "FutureSettle",
		RaiserOpcode.FutureFail => "FutureFail",
		RaiserOpcode.FutureCombine => "FutureCombine",
		RaiserOpcode.LitConv => "LitConv",
		RaiserOpcode.Try => "Try",
		RaiserOpcode.Catch => "Catch",
		RaiserOpcode.Finally => "Finally",
		RaiserOpcode.FinallyEnd => "FinallyEnd",
		RaiserOpcode.Throw => "Throw",
		RaiserOpcode.LoadInt => "LoadInt",
		RaiserOpcode.AddI64Imm => "AddI64Imm",
		RaiserOpcode.SubI64Imm => "SubI64Imm",
		RaiserOpcode.BeqI64Imm => "BeqI64Imm",
		RaiserOpcode.BneI64Imm => "BneI64Imm",
		RaiserOpcode.BltI64Imm => "BltI64Imm",
		RaiserOpcode.BleI64Imm => "BleI64Imm",
		RaiserOpcode.BgtI64Imm => "BgtI64Imm",
		RaiserOpcode.BgeI64Imm => "BgeI64Imm",
		RaiserOpcode.BrEqI64 => "BrEqI64",
		RaiserOpcode.BrNeI64 => "BrNeI64",
		RaiserOpcode.BrLtI64 => "BrLtI64",
		RaiserOpcode.BrLeI64 => "BrLeI64",
		RaiserOpcode.BrGtI64 => "BrGtI64",
		RaiserOpcode.BrGeI64 => "BrGeI64",
		RaiserOpcode.BrEqI64Imm => "BrEqI64Imm",
		RaiserOpcode.BrNeI64Imm => "BrNeI64Imm",
		RaiserOpcode.BrLtI64Imm => "BrLtI64Imm",
		RaiserOpcode.BrLeI64Imm => "BrLeI64Imm",
		RaiserOpcode.BrGtI64Imm => "BrGtI64Imm",
		RaiserOpcode.BrGeI64Imm => "BrGeI64Imm",
		RaiserOpcode.EqVal => "EqVal",
		RaiserOpcode.NeVal => "NeVal",
		RaiserOpcode.Box => "Box",
		RaiserOpcode.Unbox => "Unbox",
	};
}

// --- Format helpers ---

function isABxOp(op: RaiserOpcode): boolean {
	return op == RaiserOpcode.LoadConst || op == RaiserOpcode.Try || op == RaiserOpcode.Catch || op == RaiserOpcode.ModuleImport;
}

function isImmCompare(op: RaiserOpcode): boolean {
	return op == RaiserOpcode.BeqI64Imm || op == RaiserOpcode.BneI64Imm || op == RaiserOpcode.BltI64Imm
		|| op == RaiserOpcode.BleI64Imm || op == RaiserOpcode.BgtI64Imm || op == RaiserOpcode.BgeI64Imm;
}

function isBranchImm(op: RaiserOpcode): boolean {
	return op == RaiserOpcode.BrEqI64Imm || op == RaiserOpcode.BrNeI64Imm || op == RaiserOpcode.BrLtI64Imm
		|| op == RaiserOpcode.BrLeI64Imm || op == RaiserOpcode.BrGtI64Imm || op == RaiserOpcode.BrGeI64Imm || op == RaiserOpcode.ForLtI64Imm;
}

function isAxOp(op: RaiserOpcode): boolean {
	return op == RaiserOpcode.Jump;
}

// A register operand as its class letter and rank when the opcode's role or the operand's tag says the class, else as R and the number
function regText(op: RaiserOpcode, slot: int32, v: number): string {
	const kind = operandKind(op, slot);
	if (kind < 5) return `${regClassLetter(kind as RaiserRegClass)}${v}`;
	if (kind == OPERAND_TAGGED) return `${regClassLetter(operandClass(v as int32))}${operandRank(v as int32)}`;
	return `R${v}`;
}

export function disasmInst(inst: RaiserInstruction): string {
	const op = inst.op;
	const name = opName(op);
	const ra = regText(op, 0, inst.a);
	if (isAxOp(op)) return `${name} ${getSignedAx(inst)}`;
	if (op == RaiserOpcode.LoadInt) return `${name} ${ra} #${immValue(inst.b)}`;
	if (op == RaiserOpcode.AddI64Imm || op == RaiserOpcode.SubI64Imm) return `${name} ${ra} ${regText(op, 1, inst.b)} #${immValue(inst.c)}`;
	if (isBranchI64(op)) return `${name} ${ra} ${isBranchImm(op) ? `#${immValue(inst.b)}` : regText(op, 1, inst.b)} ->${branchOffset(inst.c)}`;
	if (isImmCompare(op)) return `${name} ${ra} #${immValue(inst.b)} ${regText(op, 2, inst.c)}`;
	if (isABxOp(op)) return `${name} ${ra} K${getBx(inst)}`;
	return `${name} ${ra} ${regText(op, 1, inst.b)} ${regText(op, 2, inst.c)}`;
}

// Disassemble a function to a single string (for test assertions)
export function disasmFunc(func: RaiserFunction): string {
	let classes = "";
	for (const cls of func.regClasses) classes = classes + regClassLetter(cls);
	let result = `; ${getFuncName(func)} classes=${classes}\n`;
	const len = getFuncCodeLen(func);
	const constants = createArrayHeap();
	for (let i = 0; i < len; i = i + 1) {
		const inst = getFuncInst(func, i);
		let line = `  ${i}: ${disasmInst(inst)}`;
		if (inst.op == RaiserOpcode.LoadConst) {
			const cIdx = getBx(inst);
			if (cIdx < getFuncConstLen(func)) {
				const cVal = getFuncConst(func, cIdx);
				line = `${line}  ; ${raiserToString(constants, cVal)}`;
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
	assert disasmInst(inst) == "AddI64 W2 W0 W1";
}

test "ABx instruction format" {
	const inst = raiserABx(RaiserOpcode.LoadConst, 0, 3);
	assert disasmInst(inst) == "LoadConst W0 K3";
}

test "Ax instruction format" {
	const inst = raiserAx(RaiserOpcode.Jump, -4);
	assert disasmInst(inst) == "Jump -4";
}

test "Halt format" {
	const inst = raiserABC(RaiserOpcode.Halt, operandTagged(2, RaiserRegClass.Ref), 0, 0);
	assert disasmInst(inst) == "Halt R2 R0 R0";
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

test "immediate operands print as numbers" {
	assert disasmInst(raiserABC(RaiserOpcode.LoadInt, 1, immField(-7), 0)) == "LoadInt W1 #-7";
	assert disasmInst(raiserABC(RaiserOpcode.AddI64Imm, 2, 0, immField(32767))) == "AddI64Imm W2 W0 #32767";
	assert disasmInst(raiserABC(RaiserOpcode.BltI64Imm, 0, immField(2), 1)) == "BltI64Imm R0 #2 R1";
}

test "branch operands print the register or the immediate and the offset" {
	assert disasmInst(raiserABC(RaiserOpcode.BrGeI64, 1, 2, branchField(-4))) == "BrGeI64 R1 R2 ->-4";
	assert disasmInst(raiserABC(RaiserOpcode.BrLtI64Imm, 0, immField(10), branchField(40000))) == "BrLtI64Imm R0 #10 ->40000";
}
