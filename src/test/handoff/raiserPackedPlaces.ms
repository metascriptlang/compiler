import { Type, TypeKind, TypeFlag, Symbol, SymbolKind, AttachedOp } from "../../ast/node";
import {
	createPrimitive, createStruct, createMaybeType, createTuple,
	createSizedArray, createDistinct, createGenericInstance, createPtr,
	createRef, createArray, createStringLiteral, stringType, voidType,
	setAttachedOp, isPlainDataType,
} from "../../checker/types";
import { makeSymbol } from "../../checker/symbol";
import { declaresUserHook } from "../../checker/instantiate";
import {
	raiserPackedEligible, classifyType,
} from "../../analyzer/classify";
import { createTransformContext } from "../../transform/context";
import { createVmLayouts, vmLayoutOf } from "../../codegen/raiser/layout";
import { packedSlotShapeOf, allocFor } from "../../codegen/raiser/valueCopy";
import {
	RaiserCompState, RaiserTryInfo, createCompState, allocPackedBlock, allocBlock, allocWord,
	allocRef, declareLocal, localSlotShape, resolveLocal, regIsFixedLocal,
	resetTemps, landResult, emitLoadConst, emitRet, emitImplicitReturn,
	emitInst, emitAbxPlaceholder, patchAbxTo, codeLen, emitJumpPlaceholder,
	patchJumpTo,
} from "../../codegen/raiser/context";
import {
	RaiserSlotShape, RaiserOpcode, RaiserRegClass, raiserABC,
} from "../../raiser/bytecode";
import {
	RaiserFunction, createRaiserFunction, createRaiserModule,
} from "../../raiser/module";
import { raiserInt } from "../../raiser/value";
import { execModule } from "../../raiser/vm";

function wordType(): Type {
	return createPrimitive(TypeKind.Int64);
}

function declaredStruct(t: Type): Type {
	t.sym = makeSymbol(t.typeName, SymbolKind.Struct, t, false);
	return t;
}

function pairType(): Type {
	return declaredStruct(createStruct("PackedPair", ["x", "y"],
		[wordType(), wordType()], true));
}

function block(words: int32): RaiserSlotShape {
	return { words, block: true };
}

function localSymbol(name: string, t: Type): Symbol {
	return makeSymbol(name, SymbolKind.Variable, t, false);
}

function built(s: RaiserCompState): RaiserFunction {
	return createRaiserFunction("packedPlaces", s.code, s.constants, 0, 0,
		s.regClasses.length, s.regClasses);
}

function hooked(t: Type, op: AttachedOp): Type {
	t.sym = makeSymbol("HookedPackedValue", SymbolKind.Struct, t, false);
	setAttachedOp(t, op, makeSymbol("packedHook", SymbolKind.Function,
		null, false));
	return t;
}

test "raiserPackedPlaces: fixed value layouts include nested Maybe and wrappers" {
	const pair = pairType();
	const alias = createPrimitive(TypeKind.Alias);
	alias.typeReturn = pair;
	const generic = createGenericInstance(pair, [wordType()]);
	generic.typeReturn = pair;
	for (const t of [pair, alias, generic, createDistinct(pair),
		createMaybeType(pair), createTuple([pair, wordType()]),
		createSizedArray(pair, 3)]) {
		assert raiserPackedEligible(t);
		const layouts = createVmLayouts();
		const shape = packedSlotShapeOf(layouts, t);
		assert shape != null && shape.block;
		assert shape!.words * 8 >= vmLayoutOf(layouts, t).size;
	}
}

test "raiserPackedPlaces: byte rounding and one-word blocks keep block identity" {
	const layouts = createVmLayouts();
	const small = declaredStruct(createStruct("SmallPacked", ["b"],
		[createPrimitive(TypeKind.Uint8)], true));
	const two = declaredStruct(createStruct("TwoPacked", ["b"],
		[createPrimitive(TypeKind.Uint16)], true));
	const nine = declaredStruct(createStruct("NinePacked", ["b"],
		[createSizedArray(createPrimitive(TypeKind.Uint8), 9)], true));
	assert packedSlotShapeOf(layouts, small)!.words == 1;
	assert packedSlotShapeOf(layouts, small)!.block;
	assert packedSlotShapeOf(layouts, two)!.words == 1;
	assert packedSlotShapeOf(layouts, nine)!.words == 2;
	assert packedSlotShapeOf(layouts, pairType())!.words == 2;
	assert packedSlotShapeOf(layouts,
		declaredStruct(createStruct("EmptyPacked", [], [], true)))!.words == 1;
}

test "raiserPackedPlaces: scalar leaves and scalar wrappers never select block ABI" {
	const layouts = createVmLayouts();
	for (const kind of [TypeKind.Int64, TypeKind.Float64, TypeKind.Boolean,
		TypeKind.Enum, TypeKind.NumberLiteral]) {
		const scalar = createPrimitive(kind);
		const alias = createPrimitive(TypeKind.Alias);
		alias.typeReturn = scalar;
		const generic = createGenericInstance(scalar, []);
		generic.typeReturn = scalar;
		for (const t of [scalar, alias, createDistinct(scalar), generic]) {
			assert raiserPackedEligible(t);
			assert packedSlotShapeOf(layouts, t) == null;
		}
	}
}

test "raiserPackedPlaces: native zero-storage fields do not disqualify a value" {
	const t = declaredStruct(createStruct("ErasedPacked",
		["nothing", "tag", "payload"],
		[voidType(), createPrimitive(TypeKind.BooleanLiteral), wordType()], true));
	t.typeFlags = t.typeFlags.incl(TypeFlag.DuVariant);
	assert raiserPackedEligible(t);
	const layouts = createVmLayouts();
	assert vmLayoutOf(layouts, t).size == 8;
	assert vmLayoutOf(layouts, t).slots.length == 1;
	assert packedSlotShapeOf(layouts, t)!.words == 1;
}

test "raiserPackedPlaces: managed and location-bearing neighbors stay legacy" {
	for (const t of [stringType(), createStringLiteral("tag"),
		createArray(wordType()), createRef(pairType()), createPtr(wordType()),
		createPrimitive(TypeKind.CString), createPrimitive(TypeKind.Span),
		createPrimitive(TypeKind.Cursor), createPrimitive(TypeKind.Borrow),
		createPrimitive(TypeKind.Lent), createPrimitive(TypeKind.Sink),
		createPrimitive(TypeKind.Function), createPrimitive(TypeKind.Unknown),
		createPrimitive(TypeKind.Union),
		createStruct("NotAValue", ["x"], [wordType()], false)]) {
		assert !raiserPackedEligible(t);
		assert !raiserPackedEligible(createStruct("NestedLegacy", ["held"], [t], true));
		assert packedSlotShapeOf(createVmLayouts(), t) == null;
	}
	assert isPlainDataType(createPtr(wordType()), declaresUserHook);
}

test "raiserPackedPlaces: each user lifecycle hook excludes nested and wrapped values" {
	for (const op of [AttachedOp.AttachedDestructor, AttachedOp.AttachedAsgn,
		AttachedOp.AttachedSink, AttachedOp.AttachedWasMoved,
		AttachedOp.AttachedDup, AttachedOp.AttachedTrace]) {
		const t = hooked(pairType(), op);
		assert declaresUserHook(t);
		assert !raiserPackedEligible(t);
		const maybe = createMaybeType(t);
		assert maybe.typeReturn == t;
		assert !raiserPackedEligible(maybe);
		assert !raiserPackedEligible(createTuple([wordType(), t]));
		assert !raiserPackedEligible(createStruct("NestedHook", ["held"], [t], true));
		const wrapper = hooked(createDistinct(wordType()), op);
		assert !raiserPackedEligible(wrapper);
		const generic = createGenericInstance(pairType(), [wordType()]);
		generic.typeReturn = t;
		assert !raiserPackedEligible(generic);
	}
}

test "raiserPackedPlaces: Maybe fixtures preserve declared hook-owner identity" {
	const plain = pairType();
	const plainMaybe = createMaybeType(plain);
	const managed = hooked(pairType(), AttachedOp.AttachedDestructor);
	const managedMaybe = createMaybeType(managed);
	assert plain.sym != managed.sym;
	assert plainMaybe.typeReturn == plain;
	assert managedMaybe.typeReturn == managed;
	assert plainMaybe != managedMaybe;
	assert raiserPackedEligible(plainMaybe);
	assert !raiserPackedEligible(managedMaybe);
}

test "raiserPackedPlaces: native layout requires declaration identity for named fixtures" {
	let message = "";
	try {
		vmLayoutOf(createVmLayouts(), createStruct("UnboundPackedFixture",
			["x"], [wordType()], true));
	} catch (error) {
		message = error.message;
	}
	assert message.includes("has no declaring symbol");
}

test "raiserPackedPlaces: unresolved cyclic and excessive layouts are refused" {
	const recursive = createStruct("RecursivePacked", ["self"], [wordType()], true);
	recursive.typeChildren[0] = recursive;
	assert !raiserPackedEligible(recursive);
	const alias = createPrimitive(TypeKind.Alias);
	alias.typeReturn = alias;
	assert !raiserPackedEligible(alias);
	assert !raiserPackedEligible(null);
	assert !raiserPackedEligible(createGenericInstance(pairType(), [wordType()]));
	assert !raiserPackedEligible(createStruct("OpenPacked", ["x"],
		[createPrimitive(TypeKind.GenericParam)], true));
	assert !raiserPackedEligible(createSizedArray(wordType(), -1));
	assert !raiserPackedEligible(createSizedArray(pairType(), 65535));
	let deep = wordType();
	for (let i = 0; i < 14; i += 1) deep = createDistinct(deep);
	assert !raiserPackedEligible(deep);
}

test "raiserPackedPlaces: eligibility does not suppress legacy cleanup or allocation" {
	const t = pairType();
	const ctx = createTransformContext();
	ctx.raiserBackend = true;
	assert raiserPackedEligible(t);
	assert classifyType(t, ctx, false).needsCleanup;
	const s = createCompState();
	const reg = allocFor(s, t);
	assert s.regClasses[reg] == RaiserRegClass.Ref;
}

test "raiserPackedPlaces: local shape is actual storage not symbol Type" {
	const s = createCompState();
	const sym = localSymbol("packed", pairType());
	const legacy = allocRef(s);
	declareLocal(s, sym, legacy);
	assert !localSlotShape(s, sym)!.block;
	const base = allocPackedBlock(s, block(3));
	declareLocal(s, sym, base, false, block(3));
	assert resolveLocal(s, sym) == base;
	assert localSlotShape(s, sym)!.words == 3;
	assert localSlotShape(s, sym)!.block;
	assert localSlotShape(s, localSymbol("missing", wordType())) == null;
	s.locals.items.shrink(1);
	assert resolveLocal(s, sym) == legacy && !localSlotShape(s, sym)!.block;
}

test "raiserPackedPlaces: local reset preserves full extent and independent borrow hold" {
	const s = createCompState();
	const shape = block(3);
	const base = allocPackedBlock(s, shape);
	declareLocal(s, localSymbol("held", pairType()), base, false, shape);
	shape.words = 1;
	assert localSlotShape(s, s.locals.items[0].sym)!.words == 3;
	assert s.locals.items[0].heldThrough == base + 2;
	allocPackedBlock(s, block(5));
	resetTemps(s);
	assert allocWord(s) == base + 3;
	assert regIsFixedLocal(s, base + 2);
	assert !regIsFixedLocal(s, base + 3);
	s.locals.items[0].heldThrough = base + 6;
	resetTemps(s);
	assert s.nextReg == base + 7;
	s.locals.items[0].heldThrough = base;
	resetTemps(s);
	assert s.nextReg == base + 3;
}

test "raiserPackedPlaces: malformed storage counts are refused before narrowing" {
	for (const words of [0, -1, 1.5, NaN, Infinity, -Infinity, 65536]) {
		const s = createCompState();
		const reg = allocWord(s);
		const shape: RaiserSlotShape = { words, block: true };
		const actions: (() => void)[] = [
			(): void => { allocPackedBlock(s, shape); },
			(): void => {
				declareLocal(s, localSymbol("invalid", wordType()), reg,
					false, shape);
			},
			(): void => { landResult(s, reg, 0, reg, reg, shape); },
			(): void => { emitRet(s, reg, shape); },
		];
		for (const action of actions) {
			let message = "";
			try { action(); } catch (error) { message = error.message; }
			assert message == "internal: invalid Raiser storage shape", message;
		}
	}
}

test "raiserPackedPlaces: scalar local and result defaults retain retargeting" {
	const s = createCompState();
	const target = allocWord(s);
	declareLocal(s, localSymbol("scalar", wordType()), target);
	const first = s.nextReg;
	const value = allocWord(s);
	emitLoadConst(s, value, raiserInt(37));
	landResult(s, target, 0, first, value);
	assert s.code.length == 1 && s.code[0].a == target;
	resetTemps(s);
	assert s.nextReg == target + 1;
	emitRet(s, target);
	emitImplicitReturn(s);
	assert s.code.length == 2 && s.code[1].op == RaiserOpcode.Ret;
	const vm = execModule(createRaiserModule("scalarDefault", [built(s)], 0));
	assert vm.error == "", vm.error;
	assert vm.exitValue.intVal == 37;
}

test "raiserPackedPlaces: packed result landing does not retarget a scalar producer" {
	const s = createCompState();
	const target = allocPackedBlock(s, block(1));
	const value = allocPackedBlock(s, block(1));
	emitLoadConst(s, value, raiserInt(41));
	landResult(s, target, 0, value, value, block(1));
	assert s.code.length == 2 && s.code[0].a == value;
	assert s.code[1].op == RaiserOpcode.MoveN && s.code[1].c == 1;
	landResult(s, target, 0, value, target, block(1));
	assert s.code.length == 2;
	emitRet(s, target);
	const vm = execModule(createRaiserModule("oneWordLanding", [built(s)], 0));
	assert vm.error == "", vm.error;
	assert vm.exitValue.intVal == 41;
}

test "raiserPackedPlaces: overlapping result landing copies every word both ways" {
	for (const backwards of [false, true]) {
		const s = createCompState();
		const base = allocPackedBlock(s, block(5));
		for (let i = 0; i < 5; i += 1) emitLoadConst(s, base + i, raiserInt(i + 10));
		const source = base + (backwards ? 1 : 0);
		const target = base + (backwards ? 0 : 1);
		landResult(s, target, 0, base, source, block(4));
		assert s.code[s.code.length - 1].op == RaiserOpcode.MoveN;
		emitInst(s, raiserABC(RaiserOpcode.Halt, 0, 0, 0));
		const vm = execModule(createRaiserModule("overlapLanding", [built(s)], 0));
		assert vm.error == "", vm.error;
		for (let i = 0; i < 4; i += 1) {
			assert vm.regs.slots[target + i] == i + (backwards ? 11 : 10);
		}
	}
}

test "raiserPackedPlaces: return pins inclusive extent in every active finally" {
	const s = createCompState();
	allocWord(s);
	const base = allocPackedBlock(s, block(4));
	s.tries.push({ finallyBody: null, routeReg: 0, inFinallyBody: false, returnTop: -1 });
	s.tries.push({ finallyBody: null, routeReg: 0, inFinallyBody: true, returnTop: -1 });
	emitRet(s, base, block(4));
	assert s.code[0].op == RaiserOpcode.RetN && s.code[0].b == 4;
	for (const guarded of s.tries) assert guarded.returnTop == base + 3;
	emitRet(s, base);
	for (const guarded of s.tries) assert guarded.returnTop == base + 3;
}

test "raiserPackedPlaces: block return survives finally temporary reuse" {
	const s = createCompState();
	const route = allocBlock(s, [RaiserRegClass.Word, RaiserRegClass.Dyn]);
	const guard: RaiserTryInfo = {
		finallyBody: null, routeReg: route, inFinallyBody: false, returnTop: -1,
	};
	s.tries.push(guard);
	const start = emitAbxPlaceholder(s, RaiserOpcode.Try);
	const shape = block(3);
	const result = allocPackedBlock(s, shape);
	for (let i = 0; i < 3; i += 1) emitLoadConst(s, result + i, raiserInt(i + 70));
	emitRet(s, result, shape);
	s.tries.pop();
	const finallyAt = codeLen(s);
	patchAbxTo(s, start, RaiserOpcode.Try, 0, finallyAt);
	emitInst(s, raiserABC(RaiserOpcode.Finally, route, 0, 0));
	resetTemps(s, guard.returnTop + 1);
	const temp = allocPackedBlock(s, block(4));
	for (let i = 0; i < 4; i += 1) emitLoadConst(s, temp + i, raiserInt(900));
	emitInst(s, raiserABC(RaiserOpcode.FinallyEnd, route, 0, 0));
	const callee = createRaiserFunction("returnThroughFinally", s.code,
		s.constants, 0, 0, s.regClasses.length, s.regClasses, [],
		{ params: [], result: shape });
	const call = raiserABC(RaiserOpcode.Call, 0, 1, 0);
	call.slot = shape.words + 1;
	const entry = createRaiserFunction("entry", [call,
		raiserABC(RaiserOpcode.Halt, 0, 0, 0)], [], 0, 0, 3,
		[RaiserRegClass.Word, RaiserRegClass.Word, RaiserRegClass.Word]);
	const vm = execModule(createRaiserModule("finallyPacked", [entry, callee], 0));
	assert vm.error == "", vm.error;
	for (let i = 0; i < 3; i += 1) assert vm.regs.slots[i] == i + 70;
}

test "raiserPackedPlaces: one-word RetN is terminal and preserves inline site" {
	const s = createCompState();
	const reg = allocPackedBlock(s, block(1));
	emitLoadConst(s, reg, raiserInt(5));
	s.site = 1;
	emitRet(s, reg, block(1));
	emitImplicitReturn(s);
	assert s.code.length == 2;
	assert s.code[1].op == RaiserOpcode.RetN && s.code[1].b == 1;
	assert s.code[1].site == 1;
	const f = createRaiserFunction("oneWordReturn", s.code, s.constants,
		0, 0, s.regClasses.length, s.regClasses,
		[{ name: "inlinedPacked", parent: 0, callLine: 9 }],
		{ params: [], result: block(1) });
	assert f.inlineSites.length == 1 && f.inlined[1] == 1;
}

test "raiserPackedPlaces: jump past RetN still requires an implicit return" {
	const s = createCompState();
	const reg = allocPackedBlock(s, block(2));
	const jump = emitJumpPlaceholder(s);
	emitRet(s, reg, block(2));
	patchJumpTo(s, jump, codeLen(s));
	emitImplicitReturn(s);
	assert s.code[s.code.length - 1].op == RaiserOpcode.Ret;
	assert s.code.length == 4;
}
