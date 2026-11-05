import { Type, TypeKind } from "../../ast/node";
import { isViewKind } from "../../checker/types";
import {
	RaiserCallShape, RaiserSlotShape, RaiserRegClass, RaiserOpcode,
	raiserABC,
} from "../../raiser/bytecode";
import { RaiserFunction, createRaiserFunction } from "../../raiser/module";
import {
	RaiserCompState, createCompState, allocBlock, allocReg, emitInst,
} from "./context";
import { createVmLayouts, VmLayouts } from "./layout";
import { packedSlotShapeOf, regClassOf, heldByLocation } from "./valueCopy";
import {
	packedFramePlace, emitLegacyToPacked, emitPackedToLegacy,
} from "./packedValues";

function slotWords(shape: RaiserSlotShape): int32 {
	if (shape.words != shape.words || shape.words < 1 ||
		shape.words > 65535 ||
		shape.words != ((shape.words as int32) as number) ||
		!shape.block && shape.words != 1) {
		throw new Error("internal: invalid packed call slot shape");
	}
	return shape.words as int32;
}

function parameterWords(actual: RaiserCallShape): int32 {
	const result = slotWords(actual.result);
	let words: int32 = 0;
	for (const param of actual.params) {
		words += slotWords(param);
		if (words + result > 65535) {
			throw new Error("internal: packed call window exceeds frame limit");
		}
	}
	if (actual.result.block && result == 65535) {
		throw new Error("internal: packed call result marker exceeds operand limit");
	}
	return words;
}

function validateSchema(
	layouts: VmLayouts, valueType: Type | null, actual: RaiserSlotShape,
): void {
	slotWords(actual);
	if (!actual.block) return;
	const expected = packedSlotShapeOf(layouts, valueType);
	if (expected == null || actual.words != expected.words) {
		throw new Error("internal: packed call schema shape mismatch");
	}
}

function validateSchemas(
	layouts: VmLayouts, paramTypes: Type[], resultType: Type | null,
	actual: RaiserCallShape,
): void {
	parameterWords(actual);
	if (paramTypes.length != actual.params.length) {
		throw new Error("internal: packed call logical arity mismatch");
	}
	validateSchema(layouts, resultType, actual.result);
	for (let i = 0; i < paramTypes.length; i += 1) {
		validateSchema(layouts, paramTypes[i], actual.params[i]);
	}
}

function appendClasses(
	s: RaiserCompState, classes: RaiserRegClass[], valueType: Type | null,
	shape: RaiserSlotShape,
): void {
	const words = slotWords(shape);
	const cls = shape.block ? RaiserRegClass.Word : regClassOf(s, valueType);
	for (let i = 0; i < words; i += 1) classes.push(cls);
}

export function allocShapedCall(
	s: RaiserCompState, paramTypes: Type[], resultType: Type | null,
	actual: RaiserCallShape,
): int32 {
	validateSchemas(createVmLayouts(), paramTypes, resultType, actual);
	const classes: RaiserRegClass[] = [];
	appendClasses(s, classes, resultType, actual.result);
	for (let i = 0; i < paramTypes.length; i += 1) {
		appendClasses(s, classes, paramTypes[i], actual.params[i]);
	}
	const base = allocBlock(s, classes);
	if (base + classes.length > 65535) {
		throw new Error("internal: packed call window exceeds frame limit");
	}
	return base;
}

export function shapedArgumentBase(
	resultBase: int32, actual: RaiserCallShape, logicalIndex: int32,
): int32 {
	parameterWords(actual);
	if (resultBase < 0 || resultBase > 65535 || logicalIndex < 0 ||
		logicalIndex >= actual.params.length) {
		throw new Error("internal: invalid packed call argument index");
	}
	let offset = slotWords(actual.result);
	for (let i = 0; i < logicalIndex; i += 1) {
		offset += slotWords(actual.params[i]);
	}
	return resultBase + offset;
}

export function emitShapedCall(
	s: RaiserCompState, resultBase: int32, bodyIdx: int32,
	actual: RaiserCallShape,
): void {
	const words = parameterWords(actual);
	const resultWords = slotWords(actual.result);
	if (bodyIdx < 0 || bodyIdx > 65535 || resultBase < 0 ||
		resultBase + resultWords + words > s.regClasses.length) {
		throw new Error("internal: invalid packed call window or body index");
	}
	let first = resultBase;
	for (const shape of [actual.result, ...actual.params]) {
		const count = slotWords(shape);
		for (let i = 0; i < count; i += 1) {
			if (shape.block && s.regClasses[first + i] != RaiserRegClass.Word) {
				throw new Error("internal: packed call block needs Word storage");
			}
		}
		first += count;
	}
	const call = raiserABC(RaiserOpcode.Call, resultBase, bodyIdx, words);
	call.slot = actual.result.block ? resultWords + 1 : 1;
	emitInst(s, call);
}

function locationResult(
	s: RaiserCompState, t: Type | null, seen: Type[],
): boolean {
	if (t == null || seen.includes(t)) return false;
	if (isViewKind(t) || t.kind == TypeKind.Ptr ||
		t.kind == TypeKind.Ref && heldByLocation(s, t.typeReturn)) return true;
	seen.push(t);
	if (t.kind == TypeKind.Function) return false;
	if (locationResult(s, t.typeReturn, seen)) return true;
	for (const child of t.typeChildren) {
		if (locationResult(s, child, seen)) return true;
	}
	return false;
}

export function createLegacyEntry(
	bodyIdx: int32, body: RaiserFunction, paramTypes: Type[],
	resultType: Type | null,
): RaiserFunction {
	const actual = body.callShape;
	if (actual == null) {
		throw new Error("internal: legacy entry requires a shaped body");
	}
	const layouts = createVmLayouts();
	validateSchemas(layouts, paramTypes, resultType, actual);
	if (body.arity != paramTypes.length) {
		throw new Error("internal: legacy entry body arity mismatch");
	}
	const s = createCompState();
	if ((actual.result.block || actual.params.some((p) => p.block)) &&
		locationResult(s, resultType, [])) {
		throw new Error("internal: packed legacy entry cannot return a location");
	}
	let physical: int32 = 0;
	for (let i = 0; i < paramTypes.length; i += 1) {
		const cls = regClassOf(s, paramTypes[i]);
		allocReg(s, cls);
		const shape = actual.params[i];
		for (let j = 0; j < slotWords(shape); j += 1) {
			if (body.regClasses[physical + j] !=
				(shape.block ? RaiserRegClass.Word : cls)) {
				throw new Error("internal: legacy entry body parameter class mismatch");
			}
		}
		physical += slotWords(shape);
	}
	const result = allocShapedCall(s, paramTypes, resultType, actual);
	for (let i = 0; i < paramTypes.length; i += 1) {
		const shape = actual.params[i];
		const dest = shapedArgumentBase(result, actual, i);
		if (shape.block) {
			const packed = emitLegacyToPacked(s, layouts, {
				reg: i, valueType: paramTypes[i],
				shape: { words: 1, block: false },
			});
			emitInst(s, raiserABC(RaiserOpcode.MoveN, dest, packed.base,
				slotWords(shape)));
		} else {
			emitInst(s, raiserABC(RaiserOpcode.Move, dest, i, 0));
		}
	}
	emitShapedCall(s, result, bodyIdx, actual);
	const returned = actual.result.block
		? emitPackedToLegacy(s, layouts, packedFramePlace(s, layouts,
			result, resultType!, actual.result)).reg : result;
	emitInst(s, raiserABC(RaiserOpcode.Ret, returned, 0, 0));
	const entry = createRaiserFunction(body.name + "_legacy", s.code,
		s.constants, paramTypes.length, 0, s.regClasses.length, s.regClasses,
		s.inlineSites);
	entry.classTypes = s.classTypes;
	entry.copyPlans = s.copyPlans;
	return entry;
}
