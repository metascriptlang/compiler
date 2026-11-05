import { Type, TypeKind } from "../../ast/node";
import {
	createPrimitive, createStruct, createMaybeType, createVar, createBorrow,
	createPtr, stringType,
} from "../../checker/types";
import {
	RaiserCallShape, RaiserSlotShape, RaiserOpcode, RaiserRegClass,
	raiserABC,
} from "../../raiser/bytecode";
import {
	RaiserFunction, createRaiserFunction, createRaiserModule,
} from "../../raiser/module";
import {
	RaiserValue, RaiserValueKind, raiserInt, raiserBool, raiserNil,
	raiserConstString, raiserObject, heapAllocObject, heapObjectSetField,
	heapObjectGetField, heapObjectCellHandles, rcDecref, rcCountOf,
} from "../../raiser/value";
import { RaiserVM, createVM, vmCallFunction, execLoop } from "../../raiser/vm";
import { createContext, load, execute } from "../../raiser/context";
import {
	createCompState, allocReg, allocRef, emitInst, emitLoadConst, addConst,
} from "../../codegen/raiser/context";
import { createVmLayouts } from "../../codegen/raiser/layout";
import {
	packedSlotShapeOf, regClassOf,
} from "../../codegen/raiser/valueCopy";
import {
	allocShapedCall, shapedArgumentBase, emitShapedCall, createLegacyEntry,
} from "../../codegen/raiser/packedCalls";

function wordType(): Type { return createPrimitive(TypeKind.Int64); }
function pairType(): Type {
	return createStruct("",  ["x", "y"], [wordType(), wordType()], true);
}
function scalar(): RaiserSlotShape { return { words: 1, block: false }; }
function block(words: number): RaiserSlotShape { return { words, block: true }; }
function shapeOf(t: Type): RaiserSlotShape {
	return packedSlotShapeOf(createVmLayouts(), t)!;
}
function halt(): RaiserFunction {
	return createRaiserFunction("halt", [
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [], 0, 0, 1, [RaiserRegClass.Word]);
}
function identity(t: Type): RaiserFunction {
	const shape = shapeOf(t);
	const classes: RaiserRegClass[] = [];
	for (let i = 0; i < shape.words; i += 1) classes.push(RaiserRegClass.Word);
	return createRaiserFunction("packedIdentity", [
		raiserABC(RaiserOpcode.RetN, 0, shape.words, 0),
	], [], 1, 0, classes.length, classes, [], {
		params: [shape], result: shape,
	});
}
function adapted(body: RaiserFunction, params: Type[], result: Type): RaiserVM {
	const entry = createLegacyEntry(2, body, params, result);
	return createVM(createRaiserModule("packedCalls", [halt(), entry, body], 0));
}
function object(vm: RaiserVM, names: string[], values: RaiserValue[]): RaiserValue {
	const handle = heapAllocObject(vm.objectHeap);
	for (let i = 0; i < names.length; i += 1) {
		heapObjectSetField(vm.arrayHeap, vm.objectHeap, handle, names[i], values[i]);
	}
	return raiserObject(handle);
}
function field(vm: RaiserVM, value: RaiserValue, name: string): RaiserValue {
	return heapObjectGetField(vm.arrayHeap, vm.objectHeap, value.intVal, name);
}

test "raiserPackedCalls: contiguous window follows actual mixed shapes" {
	const s = createCompState();
	const pair = pairType();
	const maybe = createMaybeType(createPrimitive(TypeKind.Boolean));
	const params = [wordType(), pair, stringType(), maybe, pair];
	const actual: RaiserCallShape = {
		params: [scalar(), block(2), scalar(), block(1), scalar()],
		result: block(2),
	};
	allocRef(s);
	s.nextReg = 0;
	const base = allocShapedCall(s, params, pair, actual);
	assert base == 1;
	assert shapedArgumentBase(base, actual, 0) == base + 2;
	assert shapedArgumentBase(base, actual, 1) == base + 3;
	assert shapedArgumentBase(base, actual, 2) == base + 5;
	assert shapedArgumentBase(base, actual, 3) == base + 6;
	assert shapedArgumentBase(base, actual, 4) == base + 7;
	assert s.regClasses[base + 5] == RaiserRegClass.Ref;
	assert s.regClasses[base + 6] == RaiserRegClass.Word;
	assert s.regClasses[base + 7] == RaiserRegClass.Ref;
	emitShapedCall(s, base, 7, actual);
	assert s.code[0].b == 7 && s.code[0].c == 6 && s.code[0].slot == 3;
}

test "raiserPackedCalls: malformed descriptors are rejected before narrowing" {
	const pair = pairType();
	for (const words of [0, -1, 1.5, 65536, 4294967298, 0.0 / 0.0]) {
		const s = createCompState();
		let refused = false;
		try {
			allocShapedCall(s, [pair], pair, {
				params: [block(words)], result: block(2),
			});
		} catch (error) { refused = true; }
		assert refused && s.regClasses.length == 0;
	}
	const mismatches: RaiserSlotShape[] = [block(1), block(3),
		{ words: 2, block: false }];
	for (const param of mismatches) {
		let refused = false;
		try {
			allocShapedCall(createCompState(), [pair], pair, {
				params: [param], result: block(2),
			});
		} catch (error) { refused = true; }
		assert refused;
	}
}

test "raiserPackedCalls: schema arity and scalar schemas cannot fake blocks" {
	for (const types of [[], [wordType()], [pairType(), pairType()]]) {
		let refused = false;
		try {
			allocShapedCall(createCompState(), types, pairType(), {
				params: [block(2)], result: block(2),
			});
		} catch (error) { refused = true; }
		assert refused;
	}
}

test "raiserPackedCalls: direct shaped entry refuses while adapter preserves false and nil" {
	const t = createMaybeType(createPrimitive(TypeKind.Boolean));
	const body = identity(t);
	assert body.callShape!.result.words == 1;
	for (const value of [raiserNil(), raiserBool(false), raiserBool(true)]) {
		const vm = adapted(body, [t], t);
		vmCallFunction(vm, 2, [value]);
		assert vm.error.includes("vmCallFunction RaiserValue entry/return"), vm.error;
		const result = vmCallFunction(vm, 1, [value]);
		assert vm.error == "", vm.error;
		assert result.kind == value.kind && result.intVal == value.intVal;
		assert vm.mod.functions[1].callShape == null;
		assert vm.mod.functions[1].arity == 1;
		assert vm.mod.functions[1].regClasses[0] == RaiserRegClass.Dyn;
	}
}

test "raiserPackedCalls: Pair result owns rebuilt cells and input remains borrowed" {
	const t = pairType();
	const vm = adapted(identity(t), [t], t);
	const input = object(vm, ["x", "y"], [raiserInt(13), raiserInt(29)]);
	const result = vmCallFunction(vm, 1, [input]);
	assert vm.error == "", vm.error;
	assert result.kind == RaiserValueKind.Object && result.intVal != input.intVal;
	assert field(vm, result, "x").intVal == 13;
	assert field(vm, result, "y").intVal == 29;
	rcDecref(vm.arrayHeap, vm.objectHeap, result);
	assert field(vm, input, "x").intVal == 13;
	assert rcCountOf(vm.arrayHeap, vm.objectHeap, input.intVal) == 1;
	assert heapObjectCellHandles(vm.arrayHeap).length == 0;
	rcDecref(vm.arrayHeap, vm.objectHeap, input);
	assert vm.objectHeap.freeList.length == vm.objectHeap.objects.length;
}

test "raiserPackedCalls: legacy bytecode caller releases returned aggregate" {
	const pair = pairType();
	const body = identity(pair);
	const entry = createLegacyEntry(2, body, [pair], pair);
	const s = createCompState();
	const input = allocRef(s);
	const x = allocReg(s, RaiserRegClass.Word);
	const y = allocReg(s, RaiserRegClass.Word);
	const result = allocRef(s);
	const arg = allocRef(s);
	emitInst(s, raiserABC(RaiserOpcode.NewObject, input, 0, 0));
	emitLoadConst(s, x, raiserInt(13));
	emitLoadConst(s, y, raiserInt(29));
	const xName = addConst(s, raiserConstString("x"));
	const yName = addConst(s, raiserConstString("y"));
	emitInst(s, raiserABC(RaiserOpcode.StoreField, input, xName, x));
	emitInst(s, raiserABC(RaiserOpcode.StoreField, input, yName, y));
	emitInst(s, raiserABC(RaiserOpcode.Move, arg, input, 0));
	emitInst(s, raiserABC(RaiserOpcode.Call, result, 1, 1));
	emitInst(s, raiserABC(RaiserOpcode.LoadField, x, result, xName));
	emitInst(s, raiserABC(RaiserOpcode.LoadField, y, result, yName));
	emitInst(s, raiserABC(RaiserOpcode.AddI64, x, x, y));
	emitInst(s, raiserABC(RaiserOpcode.RcDec, result, 0, 0));
	emitInst(s, raiserABC(RaiserOpcode.RcDec, input, 0, 0));
	emitInst(s, raiserABC(RaiserOpcode.Halt, x, 0, 0));
	const caller = createRaiserFunction("legacyOwner", s.code, s.constants,
		0, 0, s.regClasses.length, s.regClasses);
	const vm = createVM(createRaiserModule("legacyOwner", [caller, entry, body], 0));
	execLoop(vm);
	assert vm.error == "" && vm.exitValue.intVal == 42, vm.error;
	assert heapObjectCellHandles(vm.arrayHeap).length == 0;
	assert vm.objectHeap.freeList.length == vm.objectHeap.objects.length;
}

test "raiserPackedCalls: nested POD return rebuilds complete multiword span" {
	const pair = pairType();
	const outer = createStruct("",  ["head", "pair", "tail"],
		[wordType(), pair, wordType()], true);
	const vm = adapted(identity(outer), [outer], outer);
	const inner = object(vm, ["x", "y"], [raiserInt(17), raiserInt(23)]);
	const input = object(vm, ["head", "pair", "tail"],
		[raiserInt(11), inner, raiserInt(31)]);
	const result = vmCallFunction(vm, 1, [input]);
	assert vm.error == "", vm.error;
	assert field(vm, result, "head").intVal == 11;
	assert field(vm, field(vm, result, "pair"), "y").intVal == 23;
	assert field(vm, result, "tail").intVal == 31;
	rcDecref(vm.arrayHeap, vm.objectHeap, result);
	rcDecref(vm.arrayHeap, vm.objectHeap, input);
	assert heapObjectCellHandles(vm.arrayHeap).length == 0;
}

test "raiserPackedCalls: more than 127 words preserve last field through adapter" {
	const names: string[] = [];
	const types: Type[] = [];
	const values: RaiserValue[] = [];
	for (let i = 0; i < 130; i += 1) {
		names.push("f" + i.toString());
		types.push(wordType());
		values.push(raiserInt((i as int64) * 17 + 3));
	}
	const t = createStruct("",  names, types, true);
	const vm = adapted(identity(t), [t], t);
	const input = object(vm, names, values);
	const result = vmCallFunction(vm, 1, [input]);
	assert vm.error == "", vm.error;
	assert field(vm, result, "f0").intVal == 3;
	assert field(vm, result, "f129").intVal == 2196;
	rcDecref(vm.arrayHeap, vm.objectHeap, result);
	rcDecref(vm.arrayHeap, vm.objectHeap, input);
	assert heapObjectCellHandles(vm.arrayHeap).length == 0;
}

test "raiserPackedCalls: mixed scalar Ref Dyn and block parameters return scalar" {
	const pair = pairType();
	const maybe = createMaybeType(createPrimitive(TypeKind.Boolean));
	const w = RaiserRegClass.Word;
	const body = createRaiserFunction("mixedScalar", [
		raiserABC(RaiserOpcode.AddI64, 5, 0, 1),
		raiserABC(RaiserOpcode.AddI64, 5, 5, 2),
		raiserABC(RaiserOpcode.StrLen, 6, 3, 0),
		raiserABC(RaiserOpcode.AddI64, 5, 5, 6),
		raiserABC(RaiserOpcode.Ret, 5, 0, 0),
	], [], 4, 0, 7, [w, w, w, RaiserRegClass.Ref, RaiserRegClass.Dyn, w, w],
	[], { params: [block(2), scalar(), scalar(), scalar()], result: scalar() });
	const vm = adapted(body, [pair, wordType(), stringType(), maybe], wordType());
	const input = object(vm, ["x", "y"], [raiserInt(10), raiserInt(20)]);
	const result = vmCallFunction(vm, 1,
		[input, raiserInt(12), raiserConstString("abc"), raiserBool(false)]);
	assert vm.error == "" && result.intVal == 45, vm.error;
	assert body.arity == 4 && body.paramWords == 5;
	assert field(vm, input, "y").intVal == 20;
	rcDecref(vm.arrayHeap, vm.objectHeap, input);
	assert heapObjectCellHandles(vm.arrayHeap).length == 0;
}

test "raiserPackedCalls: mixed parameters can return only their packed block" {
	const pair = pairType();
	const w = RaiserRegClass.Word;
	const body = createRaiserFunction("mixedBlock", [
		raiserABC(RaiserOpcode.RetN, 0, 2, 0),
	], [], 2, 0, 3, [w, w, w], [], {
		params: [block(2), scalar()], result: block(2),
	});
	const vm = adapted(body, [pair, wordType()], pair);
	const input = object(vm, ["x", "y"], [raiserInt(7), raiserInt(19)]);
	const result = vmCallFunction(vm, 1, [input, raiserInt(99)]);
	assert vm.error == "" && field(vm, result, "y").intVal == 19, vm.error;
	rcDecref(vm.arrayHeap, vm.objectHeap, result);
	rcDecref(vm.arrayHeap, vm.objectHeap, input);
	assert heapObjectCellHandles(vm.arrayHeap).length == 0;
}

test "raiserPackedCalls: legacy actual aggregate stays Ref despite packed eligibility" {
	const pair = pairType();
	const s = createCompState();
	allocReg(s, RaiserRegClass.Ref);
	const out = allocReg(s, RaiserRegClass.Word);
	emitInst(s, raiserABC(RaiserOpcode.LoadField, out, 0, 0));
	emitInst(s, raiserABC(RaiserOpcode.Ret, out, 0, 0));
	const body = createRaiserFunction("legacyAggregate", s.code,
		[raiserConstString("y")], 1, 0, s.regClasses.length, s.regClasses, [], {
			params: [scalar()], result: scalar(),
		});
	const vm = adapted(body, [pair], wordType());
	const input = object(vm, ["x", "y"], [raiserInt(5), raiserInt(43)]);
	const result = vmCallFunction(vm, 1, [input]);
	assert vm.error == "" && result.intVal == 43, vm.error;
	assert !vm.mod.functions[1].code.some((i) => i.op == RaiserOpcode.MoveN);
	rcDecref(vm.arrayHeap, vm.objectHeap, input);
}

test "raiserPackedCalls: caller rooted by-ref argument stays legacy beside a block" {
	const pair = pairType();
	const borrowed = createVar(wordType());
	const s = createCompState();
	assert regClassOf(s, borrowed) == RaiserRegClass.Dyn;
	const w = RaiserRegClass.Word;
	const d = RaiserRegClass.Dyn;
	const body = createRaiserFunction("readLocation", [
		raiserABC(RaiserOpcode.LoadDeref, 3, 2, 0),
		raiserABC(RaiserOpcode.Ret, 3, 0, 0),
	], [], 2, 0, 4, [w, w, d, w], [], {
		params: [block(2), scalar()], result: scalar(),
	});
	const entry = createLegacyEntry(2, body, [pair, borrowed], wordType());
	const caller = createRaiserFunction("rootedCaller", [
		raiserABC(RaiserOpcode.AddrReg, 3, 0, 0),
		raiserABC(RaiserOpcode.Call, 1, 1, 2),
		raiserABC(RaiserOpcode.Halt, 1, 0, 0),
	], [], 0, 0, 4, [w, w, RaiserRegClass.Ref, d]);
	const vm = createVM(createRaiserModule("rooted", [caller, entry, body], 0));
	const input = object(vm, ["x", "y"], [raiserInt(5), raiserInt(6)]);
	vm.regs.slots[0] = 77;
	vm.regs.slots[2] = input.intVal;
	execLoop(vm);
	assert vm.error == "" && vm.exitValue.intVal == 77, vm.error;
	rcDecref(vm.arrayHeap, vm.objectHeap, input);
}

test "raiserPackedCalls: adapting a block refuses location bearing results" {
	const pair = pairType();
	const lent = createPrimitive(TypeKind.Lent);
	lent.typeReturn = wordType();
	for (const result of [createBorrow(wordType()), createVar(wordType()),
		lent, createPtr(wordType())]) {
		const cls = regClassOf(createCompState(), result);
		const body = createRaiserFunction("unsafeLocation", [
			raiserABC(RaiserOpcode.Ret, 2, 0, 0),
		], [], 1, 0, 3, [RaiserRegClass.Word, RaiserRegClass.Word, cls], [], {
			params: [block(2)], result: scalar(),
		});
		let message = "";
		try { createLegacyEntry(2, body, [pair], result); }
		catch (error) { message = error.message; }
		assert message.includes("packed legacy entry cannot return a location"), message;
	}
}

test "raiserPackedCalls: adapter rejects a body class inconsistent with scalar schema" {
	const body = createRaiserFunction("wrongClass", [
		raiserABC(RaiserOpcode.Ret, 0, 0, 0),
	], [], 1, 0, 1, [RaiserRegClass.Ref], [], {
		params: [scalar()], result: scalar(),
	});
	let message = "";
	try { createLegacyEntry(2, body, [wordType()], wordType()); }
	catch (error) { message = error.message; }
	assert message.includes("parameter class mismatch"), message;
}

test "raiserPackedCalls: context entry executes legacy adapter and refuses shaped entry" {
	const pair = pairType();
	const body = createRaiserFunction("constantPair", [
		raiserABC(RaiserOpcode.RetN, 0, 2, 0),
	], [], 0, 0, 2, [RaiserRegClass.Word, RaiserRegClass.Word], [], {
		params: [], result: block(2),
	});
	const ctx = createContext();
	load(ctx, createRaiserModule("directEntry", [body], 0));
	assert !execute(ctx) && ctx.lastError.includes("entry/strand RaiserValue return"), ctx.lastError;
	const entry = createLegacyEntry(1, body, [], pair);
	load(ctx, createRaiserModule("adaptedEntry", [entry, body], 0));
	assert execute(ctx), ctx.lastError;
	assert ctx.lastResult.kind == RaiserValueKind.Object;
	rcDecref(ctx.arrayHeap, ctx.objectHeap, ctx.lastResult);
	assert heapObjectCellHandles(ctx.arrayHeap).length == 0;
}

test "raiserPackedCalls: ordinary closure calls the adapter not the shaped body" {
	const t = createMaybeType(createPrimitive(TypeKind.Boolean));
	const body = identity(t);
	const entry = createLegacyEntry(2, body, [t], t);
	const s = createCompState();
	const closure = allocRef(s);
	const result = allocReg(s, RaiserRegClass.Dyn);
	const arg = allocReg(s, RaiserRegClass.Dyn);
	allocRef(s);
	emitLoadConst(s, arg, raiserBool(false));
	emitInst(s, raiserABC(RaiserOpcode.CallClosure, result, closure, 2));
	emitInst(s, raiserABC(RaiserOpcode.Halt, result, 0, 0));
	const caller = createRaiserFunction("closureCaller", s.code, s.constants,
		0, 0, s.regClasses.length, s.regClasses);
	const vm = createVM(createRaiserModule("closureAdapter", [caller, entry, body], 0));
	const pair = object(vm, ["fn", "env"], [raiserInt(1), raiserNil()]);
	vm.regs.slots[closure] = pair.intVal;
	execLoop(vm);
	assert vm.error == "", vm.error;
	assert vm.exitValue.kind == RaiserValueKind.Bool && vm.exitValue.intVal == 0;
	rcDecref(vm.arrayHeap, vm.objectHeap, pair);
}
