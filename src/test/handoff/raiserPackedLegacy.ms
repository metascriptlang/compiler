import { Type, TypeKind, TypeFlag } from "../../ast/node";
import {
	createPrimitive, createStruct, createMaybeType, createTuple,
	createSizedArray, createDistinct, createGenericInstance,
	createNumberLiteral, createBooleanLiteral, createEnum, createEnumLiteral,
	voidType, stringType, enumMemberValue,
} from "../../checker/types";
import { createVmLayouts, vmLayoutOf } from "../../codegen/raiser/layout";
import {
	RaiserCompState, createCompState, emitInst, emitLoadConst,
	allocRef, allocReg, addConst,
} from "../../codegen/raiser/context";
import {
	RaiserFramePlace, RaiserLegacyValue, allocPackedValue, packedFramePlace,
	packedField, packedIndex, emitPackedLoad, emitPackedStore, emitPackedCopy,
	emitLegacyToPacked, emitPackedToLegacy,
} from "../../codegen/raiser/packedValues";
import {
	packedSlotShapeOf, structShapeOperand, slotClassesOf, fieldInst,
	newArrayInst, regClassOf,
} from "../../codegen/raiser/valueCopy";
import {
	RaiserOpcode, RaiserRegClass, raiserABC, RaiserSlotShape,
} from "../../raiser/bytecode";
import { createRaiserFunction, createRaiserModule } from "../../raiser/module";
import {
	RaiserValue, RaiserValueKind, raiserInt, raiserFloat, raiserBool,
	raiserNil, raiserConstString, bitsToFloat, slotWord,
	heapObjectCellHandles, heapSeqHandles,
} from "../../raiser/value";
import { RaiserVM, execModule } from "../../raiser/vm";
import { MemKind } from "../../raiser/layout";
import { execFileCapture, cwd } from "std/process";
import { writeFile } from "std/fs";

function floatBits(n: float64): int64 {
	return slotWord(RaiserRegClass.Float, raiserFloat(n));
}

function primitive(kind: TypeKind): Type { return createPrimitive(kind); }

function record(names: string[], children: Type[]): Type {
	return createStruct("", names, children, true);
}

function run(s: RaiserCompState): RaiserVM {
	emitInst(s, raiserABC(RaiserOpcode.Halt, 0, 0, 0));
	const f = createRaiserFunction("packedLegacy", s.code, s.constants,
		0, 0, s.regClasses.length, s.regClasses);
	f.classTypes = s.classTypes;
	return execModule(createRaiserModule("packedLegacy", [f], 0));
}

function value(s: RaiserCompState, v: RaiserValue): int32 {
	const cls = v.kind == RaiserValueKind.Float ? RaiserRegClass.Float
		: v.kind == RaiserValueKind.Bool ? RaiserRegClass.Bool
		: v.kind == RaiserValueKind.Int ? RaiserRegClass.Word : RaiserRegClass.Ref;
	const reg = allocReg(s, cls);
	emitLoadConst(s, reg, v);
	return reg;
}

function legacy(reg: int32, valueType: Type): RaiserLegacyValue {
	return { reg, valueType, shape: { words: 1, block: false } };
}

function object(s: RaiserCompState, t: Type, values: int32[], laid: boolean): int32 {
	const reg = allocRef(s);
	emitInst(s, raiserABC(RaiserOpcode.NewObject, reg, laid
		? structShapeOperand(s, t, t.typeNames, slotClassesOf(s, t)) : 0, 0));
	for (let i = 0; i < values.length; i += 1) {
		if (s.regClasses[values[i]] == RaiserRegClass.Ref ||
			s.regClasses[values[i]] == RaiserRegClass.Dyn) {
			emitInst(s, raiserABC(RaiserOpcode.RcInc, values[i], 0, 0));
		}
		emitInst(s, fieldInst(s, laid ? t : null, t.typeNames[i],
			RaiserOpcode.StoreField, RaiserOpcode.StoreSlot, reg,
			addConst(s, raiserConstString(t.typeNames[i])), values[i]));
	}
	return reg;
}

function loadField(s: RaiserCompState, reg: int32, name: string, t: Type): int32 {
	const result = allocReg(s, regClassOf(s, t));
	emitInst(s, fieldInst(s, null, name, RaiserOpcode.LoadField,
		RaiserOpcode.LoadSlot, result, reg, addConst(s, raiserConstString(name))));
	if (s.regClasses[result] == RaiserRegClass.Ref ||
		s.regClasses[result] == RaiserRegClass.Dyn) {
		emitInst(s, raiserABC(RaiserOpcode.RcInc, result, 0, 0));
	}
	return result;
}

function array(s: RaiserCompState, elements: int32[], elementType: Type | null): int32 {
	const reg = allocRef(s);
	emitInst(s, newArrayInst(s, reg, 0, elementType));
	for (const element of elements) {
		if (s.regClasses[element] == RaiserRegClass.Ref ||
			s.regClasses[element] == RaiserRegClass.Dyn) {
			emitInst(s, raiserABC(RaiserOpcode.RcInc, element, 0, 0));
		}
		emitInst(s, raiserABC(RaiserOpcode.ArrayPush, reg, element, 0));
	}
	return reg;
}

function loadIndex(s: RaiserCompState, reg: int32, at: int32, t: Type): int32 {
	const result = allocReg(s, regClassOf(s, t));
	emitInst(s, raiserABC(RaiserOpcode.LoadIndex, result, reg,
		value(s, raiserInt(at as int64))));
	return result;
}

function drop(s: RaiserCompState, reg: int32): void {
	emitInst(s, raiserABC(RaiserOpcode.RcDec, reg, 0, 0));
}

test "raiserPackedLegacy: scalar native widths preserve neighbors" {
	const kinds = [TypeKind.Int8, TypeKind.Uint8, TypeKind.Int16,
		TypeKind.Uint16, TypeKind.Int32, TypeKind.Uint32, TypeKind.Int64,
		TypeKind.Uint64, TypeKind.Float32, TypeKind.Float64, TypeKind.Boolean];
	for (const kind of kinds) {
		const s = createCompState();
		const layouts = createVmLayouts();
		const t = record(["left", "n", "right"],
			[primitive(TypeKind.Uint8), primitive(kind), primitive(TypeKind.Uint8)]);
		const place = allocPackedValue(s, layouts, t);
		emitPackedStore(s, layouts, packedField(s, layouts, place, "left"),
			value(s, raiserInt(171)));
		emitPackedStore(s, layouts, packedField(s, layouts, place, "right"),
			value(s, raiserInt(205)));
		const v = kind == TypeKind.Boolean ? raiserBool(true)
			: kind == TypeKind.Float32 || kind == TypeKind.Float64 ? raiserFloat(-1.5)
			: raiserInt(kind == TypeKind.Int8 || kind == TypeKind.Int16 ||
				kind == TypeKind.Int32 || kind == TypeKind.Int64 ? -7 : 217);
		emitPackedStore(s, layouts, packedField(s, layouts, place, "n"), value(s, v));
		const n = emitPackedLoad(s, layouts, packedField(s, layouts, place, "n"));
		const a = emitPackedLoad(s, layouts, packedField(s, layouts, place, "left"));
		const b = emitPackedLoad(s, layouts, packedField(s, layouts, place, "right"));
		const vm = run(s);
		assert vm.error == "", vm.error;
		assert vm.regs.slots[a] == 171 && vm.regs.slots[b] == 205;
		assert vm.regs.slots[n] == (v.kind == RaiserValueKind.Float
			? floatBits(v.floatVal) : v.intVal);
	}
}

test "raiserPackedLegacy: one Word Maybe distinguishes absent and present false" {
	const t = createMaybeType(primitive(TypeKind.Boolean));
	for (const v of [raiserNil(), raiserBool(false), raiserBool(true)]) {
		const s = createCompState();
		const layouts = createVmLayouts();
		const packed = emitLegacyToPacked(s, layouts, legacy(value(s, v), t));
		assert packed.words == 1;
		const present = emitPackedLoad(s, layouts,
			packedField(s, layouts, packed, "present"));
		const rebuilt = emitPackedToLegacy(s, layouts, packed);
		const nil = allocReg(s, RaiserRegClass.Bool);
		emitInst(s, raiserABC(RaiserOpcode.IsKind, nil, rebuilt.reg,
			RaiserValueKind.Nil as int32));
		const vm = run(s);
		assert vm.error == "", vm.error;
		assert vm.regs.slots[present] == (v.kind == RaiserValueKind.Nil ? 0 : 1);
		assert vm.regs.slots[nil] == (v.kind == RaiserValueKind.Nil ? 1 : 0);
	}
}

test "raiserPackedLegacy: wide scalar Maybe round trips bits not truthiness" {
	const high = bitsToFloat(-2251799813685243);
	for (const v of [raiserInt(-9223372036854775807), raiserInt(0),
		raiserFloat(-0.0), raiserFloat(high)]) {
		const s = createCompState();
		const layouts = createVmLayouts();
		const t = createMaybeType(primitive(v.kind == RaiserValueKind.Float
			? TypeKind.Float64 : TypeKind.Uint64));
		const packed = emitLegacyToPacked(s, layouts, legacy(value(s, v), t));
		const rebuilt = emitPackedToLegacy(s, layouts, packed);
		const result = allocReg(s, v.kind == RaiserValueKind.Float
			? RaiserRegClass.Float : RaiserRegClass.Word);
		emitInst(s, raiserABC(RaiserOpcode.Move, result, rebuilt.reg, 0));
		const vm = run(s);
		assert vm.error == "", vm.error;
		assert vm.regs.slots[result] == (v.kind == RaiserValueKind.Float
			? floatBits(v.floatVal) : v.intVal);
	}
}

test "raiserPackedLegacy: nested laid and unlaid POD records rebuild ordinary cells" {
	const n = primitive(TypeKind.Int64);
	const inner = record(["x", "y"], [n, primitive(TypeKind.Float64)]);
	const outer = record(["head", "inner", "tail"], [n, inner, n]);
	for (const laid of [false, true]) {
		const s = createCompState();
		const layouts = createVmLayouts();
		const oldInner = object(s, inner,
			[value(s, raiserInt(-9223372036854775807)), value(s, raiserFloat(-0.0))], laid);
		const old = object(s, outer,
			[value(s, raiserInt(11)), oldInner, value(s, raiserInt(29))], laid);
		const packed = emitLegacyToPacked(s, layouts, legacy(old, outer));
		const rebuilt = emitPackedToLegacy(s, layouts, packed).reg;
		const rebuiltInner = loadField(s, rebuilt, "inner", inner);
		const x = loadField(s, rebuiltInner, "x", n);
		const y = loadField(s, rebuiltInner, "y", primitive(TypeKind.Float64));
		const tail = loadField(s, rebuilt, "tail", n);
		drop(s, rebuiltInner);
		drop(s, rebuilt);
		drop(s, old);
		drop(s, oldInner);
		const vm = run(s);
		assert vm.error == "", vm.error;
		assert vm.regs.slots[x] == -9223372036854775807;
		assert vm.regs.slots[y] == floatBits(-0.0) && vm.regs.slots[tail] == 29;
		assert vm.regs.slots[rebuilt] == 0 && vm.regs.slots[old] == 0;
		assert heapObjectCellHandles(vm.arrayHeap).length == 0;
		assert heapSeqHandles(vm.arrayHeap).length == 0;
	}
}

test "raiserPackedLegacy: Tuple and fixed array carriers use legacy index operations" {
	const n = primitive(TypeKind.Int16);
	for (const t of [createTuple([n, n, n]), createSizedArray(n, 3)]) {
		const s = createCompState();
		const layouts = createVmLayouts();
		const old = array(s, [value(s, raiserInt(-301)), value(s, raiserInt(302)),
			value(s, raiserInt(-303))], n);
		const packed = emitLegacyToPacked(s, layouts, legacy(old, t));
		const rebuilt = emitPackedToLegacy(s, layouts, packed).reg;
		const first = loadIndex(s, rebuilt, 0, n);
		const last = loadIndex(s, rebuilt, 2, n);
		drop(s, old);
		drop(s, rebuilt);
		const vm = run(s);
		assert vm.error == "", vm.error;
		assert vm.regs.slots[first] == -301 && vm.regs.slots[last] == -303;
	}
}

test "raiserPackedLegacy: heterogeneous Tuple and zero-storage entries retain indices" {
	const n = primitive(TypeKind.Int32);
	const f = primitive(TypeKind.Float64);
	const t = createTuple([voidType(), n, f]);
	const s = createCompState();
	const layouts = createVmLayouts();
	const old = array(s, [value(s, raiserNil()), value(s, raiserInt(47)),
		value(s, raiserFloat(-0.0))], null);
	const rebuilt = emitPackedToLegacy(s, layouts,
		emitLegacyToPacked(s, layouts, legacy(old, t))).reg;
	const first = loadIndex(s, rebuilt, 1, n);
	const last = loadIndex(s, rebuilt, 2, f);
	const vm = run(s);
	assert vm.error == "", vm.error;
	assert vm.regs.slots[first] == 47 && vm.regs.slots[last] == floatBits(-0.0);
}

test "raiserPackedLegacy: resolved aggregate and scalar wrappers have native metadata" {
	const layouts = createVmLayouts();
	const n = primitive(TypeKind.Int16);
	const aggregate = record(["x"], [n]);
	for (const t of [aggregate, n]) {
		const alias = primitive(TypeKind.Alias);
		alias.typeReturn = t;
		const generic = createGenericInstance(t, [t]);
		generic.typeReturn = t;
		for (const wrapper of [alias, createDistinct(t), generic]) {
			const got = vmLayoutOf(createVmLayouts(), wrapper);
			const expected = vmLayoutOf(layouts, t);
			assert got.kind == expected.kind && got.size == expected.size;
			assert got.slots.length == expected.slots.length;
		}
	}
	const literal = createNumberLiteral("7", n);
	assert vmLayoutOf(layouts, literal).kind == MemKind.I16;
	const generic = createGenericInstance(aggregate, [aggregate]);
	generic.typeReturn = aggregate;
	const s = createCompState();
	const old = object(s, aggregate, [value(s, raiserInt(71))], true);
	const rebuilt = emitPackedToLegacy(s, layouts,
		emitLegacyToPacked(s, layouts, legacy(old, generic))).reg;
	const result = loadField(s, rebuilt, "x", n);
	const vm = run(s);
	assert vm.error == "" && vm.regs.slots[result] == 71, vm.error;
}

test "raiserPackedLegacy: wrapper metadata matches a native C layout oracle" {
	const n = primitive(TypeKind.Uint16);
	const generic = createGenericInstance(n, [n]);
	generic.typeReturn = n;
	const literal = createNumberLiteral("3", primitive(TypeKind.Int32));
	const pair = record(["tag", "value"], [primitive(TypeKind.Uint8), generic]);
	const wrapped = createGenericInstance(pair, [pair]);
	wrapped.typeReturn = pair;
	const layouts = createVmLayouts();
	const a = vmLayoutOf(layouts, wrapped);
	const b = vmLayoutOf(layouts, literal);
	const text = "#include <stdint.h>\n#include <stddef.h>\n"
		+ "struct Pair { uint8_t tag; uint16_t value; };\n"
		+ `_Static_assert(sizeof(struct Pair)==${a.size}, "size");\n`
		+ `_Static_assert(_Alignof(struct Pair)==${a.align}, "align");\n`
		+ `_Static_assert(offsetof(struct Pair,value)==${a.slots[1].offset}, "offset");\n`
		+ `_Static_assert(sizeof(int32_t)==${b.size}, "literal size");\n`;
	const file = cwd() + "/scratch/typed-memory/packedLegacy/layoutOracle.c";
	assert writeFile(file, text).ok;
	const compiled = execFileCapture("cc", ["-std=c11", "-fsyntax-only", file]);
	assert compiled.ok, compiled.ok ? "" : compiled.error.errorOutput;
	assert a.slots[1].kind == MemKind.U16 && b.kind == MemKind.I32;
}

test "raiserPackedLegacy: erased literals and void restore declared legacy metadata" {
	const tag = createBooleanLiteral(true);
	const enumType = createEnum("", ["Zero", "One"]);
	const lit = createEnumLiteral(enumType, "One");
	const t = record(["tag", "enumTag", "nothing", "x"],
		[tag, lit, voidType(), primitive(TypeKind.Int64)]);
	t.typeFlags = t.typeFlags.incl(TypeFlag.DuVariant);
	const s = createCompState();
	const layouts = createVmLayouts();
	const old = object(s, t, [value(s, raiserBool(true)),
		value(s, raiserInt(enumMemberValue(enumType, 1) as int64)), value(s, raiserNil()),
		value(s, raiserInt(83))], false);
	const packed = emitLegacyToPacked(s, layouts, legacy(old, t));
	assert vmLayoutOf(layouts, t).slots.length == 1 && packed.words == 1;
	const rebuilt = emitPackedToLegacy(s, layouts, packed).reg;
	const bool = loadField(s, rebuilt, "tag", tag);
	const enumTag = loadField(s, rebuilt, "enumTag", lit);
	const x = loadField(s, rebuilt, "x", primitive(TypeKind.Int64));
	const vm = run(s);
	assert vm.error == "", vm.error;
	assert vm.regs.slots[bool] == 1 && vm.regs.slots[enumTag] == enumMemberValue(enumType, 1) as int64;
	assert vm.regs.slots[x] == 83;
}

test "raiserPackedLegacy: exact subcopies preserve neighbors in both overlap directions" {
	for (const reverse of [false, true]) {
		const s = createCompState();
		const layouts = createVmLayouts();
		const bytes = createSizedArray(primitive(TypeKind.Uint8), 24);
		const block = allocPackedValue(s, layouts, bytes);
		for (let i = 0; i < 24; i += 1) {
			emitPackedStore(s, layouts, packedIndex(s, layouts, block, i),
				value(s, raiserInt((i + 1) as int64)));
		}
		const part = createSizedArray(primitive(TypeKind.Uint8), 13);
		const from = reverse ? 4 : 1;
		const to = reverse ? 1 : 4;
		const src: RaiserFramePlace = { base: block.base, offset: from,
			valueType: part, words: block.words, whole: false };
		const dst: RaiserFramePlace = { base: block.base, offset: to,
			valueType: part, words: block.words, whole: false };
		emitPackedCopy(s, layouts, dst, src);
		const results: int32[] = [];
		for (let i = 0; i < 24; i += 1) {
			results.push(emitPackedLoad(s, layouts, packedIndex(s, layouts, block, i)));
		}
		const vm = run(s);
		assert vm.error == "", vm.error;
		for (let i = 0; i < 24; i += 1) {
			const expected = i >= to && i < to + 13 ? i - to + from + 1 : i + 1;
			assert vm.regs.slots[results[i]] == expected as int64;
		}
	}
}

test "raiserPackedLegacy: raw F32 and F64 subcopies retain NaN payload bits" {
	for (const kind of [TypeKind.Float32, TypeKind.Float64]) {
		const s = createCompState();
		const layouts = createVmLayouts();
		const bytes = createSizedArray(primitive(TypeKind.Uint8), 32);
		const block = allocPackedValue(s, layouts, bytes);
		const bits: int64 = kind == TypeKind.Float32 ? 2141266757 : 9218868437227405397;
		const width = kind == TypeKind.Float32 ? 4 : 8;
		for (let i = 0; i < width; i += 1) {
			const byte = (bits >> ((i * 8) as int64)) & 255;
			emitPackedStore(s, layouts, packedIndex(s, layouts, block, i + 1),
				value(s, raiserInt(byte)));
		}
		const from: RaiserFramePlace = { base: block.base, offset: 1,
			valueType: primitive(kind), words: block.words, whole: false };
		const to: RaiserFramePlace = { base: block.base, offset: 17,
			valueType: primitive(kind), words: block.words, whole: false };
		emitPackedCopy(s, layouts, to, from);
		const results: int32[] = [];
		for (let i = 0; i < width; i += 1) {
			results.push(emitPackedLoad(s, layouts,
				packedIndex(s, layouts, block, i + 17)));
		}
		const vm = run(s);
		assert vm.error == "", vm.error;
		for (let i = 0; i < width; i += 1) {
			assert vm.regs.slots[results[i]] == ((bits >> ((i * 8) as int64)) & 255);
		}
		for (const inst of s.code) {
			if (inst.op == RaiserOpcode.LoadFrame || inst.op == RaiserOpcode.StoreFrame) {
				assert inst.slot != (MemKind.F32 as int32) && inst.slot != (MemKind.F64 as int32);
			}
		}
	}
}

test "raiserPackedLegacy: whole spans transfer every Word using MoveN" {
	const s = createCompState();
	const layouts = createVmLayouts();
	const t = createSizedArray(primitive(TypeKind.Int64), 3);
	const src = allocPackedValue(s, layouts, t);
	const dst = allocPackedValue(s, layouts, t);
	for (let i = 0; i < 3; i += 1) {
		emitPackedStore(s, layouts, packedIndex(s, layouts, src, i),
			value(s, raiserInt((i + 91) as int64)));
	}
	emitPackedCopy(s, layouts, dst, src);
	assert s.code[s.code.length - 1].op == RaiserOpcode.MoveN;
	const vm = run(s);
	assert vm.error == "", vm.error;
	for (let i = 0; i < 3; i += 1) assert vm.regs.slots[dst.base + i] == (i + 91) as int64;
}

test "raiserPackedLegacy: actual shape and backing range are mandatory" {
	const s = createCompState();
	const layouts = createVmLayouts();
	const t = record(["x", "y"], [primitive(TypeKind.Int64), primitive(TypeKind.Int64)]);
	const place = allocPackedValue(s, layouts, t);
	const shapes: RaiserSlotShape[] = [
		{ words: 1, block: false }, { words: 1, block: true },
		{ words: 3, block: true }, { words: NaN, block: true },
	];
	for (const shape of shapes) {
		let message = "";
		try { packedFramePlace(s, layouts, place.base, t, shape); }
		catch (error) { message = error.message; }
		assert message.includes("shape mismatch"), message;
	}
	const bad: RaiserFramePlace = { base: place.base, offset: 9,
		valueType: primitive(TypeKind.Int64), words: 2, whole: false };
	let message = "";
	try { emitPackedLoad(s, layouts, bad); } catch (error) { message = error.message; }
	assert message.includes("extent"), message;
	message = "";
	try { emitLegacyToPacked(s, layouts, { reg: place.base, valueType: t,
		shape: { words: 2, block: true } }); } catch (error) { message = error.message; }
	assert message.includes("carrier"), message;
	message = "";
	try { emitLegacyToPacked(s, layouts, legacy(place.base, t)); }
	catch (error) { message = error.message; }
	assert message.includes("class mismatch"), message;
}

test "raiserPackedLegacy: managed neighbors and invalid projections are refused" {
	const s = createCompState();
	const layouts = createVmLayouts();
	let message = "";
	try { allocPackedValue(s, layouts, record(["text"], [stringType()])); }
	catch (error) { message = error.message; }
	assert message.includes("no packed block"), message;
	const t = createSizedArray(primitive(TypeKind.Int64), 2);
	const place = allocPackedValue(s, layouts, t);
	for (const index of [-1, 2, 0.5, NaN, Infinity]) {
		message = "";
		try { packedIndex(s, layouts, place, index); }
		catch (error) { message = error.message; }
		assert message.includes("out of bounds"), message;
	}
}

test "raiserPackedLegacy: malformed legacy scalar kind range and record shape trap" {
	const n = primitive(TypeKind.Uint8);
	const t = record(["n"], [n]);
	for (const bad of [raiserInt(256), raiserInt(-1), raiserBool(false), raiserNil()]) {
		const s = createCompState();
		const layouts = createVmLayouts();
		const old = object(s, t, [value(s, bad)], false);
		emitLegacyToPacked(s, layouts, legacy(old, t));
		const vm = run(s);
		assert vm.error != "";
	}
	const s = createCompState();
	const old = object(s, t, [], false);
	emitLegacyToPacked(s, createVmLayouts(), legacy(old, t));
	assert run(s).error.includes("required field");
}

test "raiserPackedLegacy: malformed fixed-array lengths never truncate" {
	for (const count of [0, 1, 3]) {
		const s = createCompState();
		const n = primitive(TypeKind.Int64);
		const elements: int32[] = [];
		for (let i = 0; i < count; i += 1) elements.push(value(s, raiserInt(i as int64)));
		const old = array(s, elements, n);
		emitLegacyToPacked(s, createVmLayouts(), legacy(old, createSizedArray(n, 2)));
		assert run(s).error.includes("fixed aggregate length");
	}
}

test "raiserPackedLegacy: nullable record fields round trip absent zero false and NaN" {
	const flag = createMaybeType(primitive(TypeKind.Boolean));
	const num = createMaybeType(primitive(TypeKind.Float64));
	const inner = record(["flag", "num"], [flag, num]);
	const outer = record(["inner"], [createMaybeType(inner)]);
	for (const absent of [false, true]) {
		const s = createCompState();
		const layouts = createVmLayouts();
		const oldInner = object(s, inner, [value(s, absent ? raiserNil()
			: raiserBool(false)), value(s, absent ? raiserNil()
				: raiserFloat(bitsToFloat(9221120237041090629)))], false);
		const old = object(s, outer, [oldInner], true);
		const packed = emitLegacyToPacked(s, layouts, legacy(old, outer));
		const rebuilt = emitPackedToLegacy(s, layouts, packed).reg;
		const rebuiltInner = loadField(s, rebuilt, "inner", createMaybeType(inner));
		const f = loadField(s, rebuiltInner, "flag", flag);
		const n = loadField(s, rebuiltInner, "num", num);
		const isNil = allocReg(s, RaiserRegClass.Bool);
		emitInst(s, raiserABC(RaiserOpcode.IsKind, isNil, f,
			RaiserValueKind.Nil as int32));
		const isFloat = allocReg(s, RaiserRegClass.Bool);
		emitInst(s, raiserABC(RaiserOpcode.IsKind, isFloat, n,
			RaiserValueKind.Float as int32));
		drop(s, rebuiltInner);
		drop(s, rebuilt);
		drop(s, old);
		drop(s, oldInner);
		const vm = run(s);
		assert vm.error == "", vm.error;
		assert vm.regs.slots[isNil] == (absent ? 1 : 0);
		assert vm.regs.slots[isFloat] == (absent ? 0 : 1);
		assert heapObjectCellHandles(vm.arrayHeap).length == 0;
	}
}

test "raiserPackedLegacy: missing nullable and erased fields trap rather than default" {
	const maybe = createMaybeType(primitive(TypeKind.Boolean));
	const literal = createBooleanLiteral(true);
	for (const t of [record(["maybe"], [maybe]), record(["tag"], [literal])]) {
		if (t.typeNames[0] == "tag") t.typeFlags = t.typeFlags.incl(TypeFlag.DuVariant);
		const s = createCompState();
		const old = object(s, t, [], false);
		emitLegacyToPacked(s, createVmLayouts(), legacy(old, t));
		const vm = run(s);
		assert vm.error.includes("required field"), vm.error;
	}
	const s = createCompState();
	const t = record(["tag"], [literal]);
	t.typeFlags = t.typeFlags.incl(TypeFlag.DuVariant);
	const old = object(s, t, [value(s, raiserBool(false))], false);
	emitLegacyToPacked(s, createVmLayouts(), legacy(old, t));
	assert run(s).error.includes("invalid legacy literal");
}

test "raiserPackedLegacy: reordered laid legacy fields are read by required names" {
	const n = primitive(TypeKind.Int64);
	const declared = record(["a", "b"], [n, n]);
	const reordered = record(["b", "a"], [n, n]);
	const s = createCompState();
	const layouts = createVmLayouts();
	const old = object(s, reordered, [value(s, raiserInt(79)), value(s, raiserInt(23))], true);
	const packed = emitLegacyToPacked(s, layouts, legacy(old, declared));
	const a = emitPackedLoad(s, layouts, packedField(s, layouts, packed, "a"));
	const b = emitPackedLoad(s, layouts, packedField(s, layouts, packed, "b"));
	const vm = run(s);
	assert vm.error == "" && vm.regs.slots[a] == 23 && vm.regs.slots[b] == 79, vm.error;
	for (const instruction of s.code) {
		assert instruction.op != RaiserOpcode.LoadSlot;
	}
}

test "raiserPackedLegacy: empty and zero-length aggregates keep complete legacy shape" {
	for (const t of [record([], []), createTuple([]),
		createSizedArray(primitive(TypeKind.Int32), 0)]) {
		const s = createCompState();
		const layouts = createVmLayouts();
		const old = t.kind == TypeKind.Struct ? object(s, t, [], false)
			: array(s, [], t.kind == TypeKind.Tuple ? null : t.typeReturn);
		const packed = emitLegacyToPacked(s, layouts, legacy(old, t));
		const rebuilt = emitPackedToLegacy(s, layouts, packed).reg;
		const check = allocReg(s, RaiserRegClass.Bool);
		emitInst(s, raiserABC(RaiserOpcode.IsKind, check, rebuilt,
			(t.kind == TypeKind.Struct ? RaiserValueKind.Object : RaiserValueKind.Array) as int32));
		drop(s, old);
		drop(s, rebuilt);
		const vm = run(s);
		assert vm.error == "" && vm.regs.slots[check] == 1, vm.error;
		assert heapObjectCellHandles(vm.arrayHeap).length == 0;
		assert heapSeqHandles(vm.arrayHeap).length == 0;
	}
}

test "raiserPackedLegacy: unrepresentable present absent nested Maybe traps" {
	const s = createCompState();
	const layouts = createVmLayouts();
	const t = createMaybeType(createMaybeType(primitive(TypeKind.Boolean)));
	const packed = allocPackedValue(s, layouts, t);
	emitPackedStore(s, layouts, packedField(s, layouts, packed, "present"),
		value(s, raiserBool(true)));
	emitPackedToLegacy(s, layouts, packed);
	const vm = run(s);
	assert vm.error.includes("not representable by legacy Maybe"), vm.error;
}

test "raiserPackedLegacy: large partial copy uses one encodable Word scratch" {
	const s = createCompState();
	const layouts = createVmLayouts();
	const t = record(["head", "bytes"], [primitive(TypeKind.Uint8),
		createSizedArray(primitive(TypeKind.Uint8), 32000)]);
	const source = allocPackedValue(s, layouts, t);
	const destination = allocPackedValue(s, layouts, t);
	const from = packedField(s, layouts, source, "bytes");
	const to = packedField(s, layouts, destination, "bytes");
	assert from.offset == 1 && to.offset == 1;
	const backingWords = s.regClasses.length;
	assert backingWords == 8002;
	emitPackedCopy(s, layouts, to, from);
	assert s.regClasses.length == backingWords + 1,
		`raw copy grew ${s.regClasses.length - backingWords} scratch Words`;
	emitInst(s, raiserABC(RaiserOpcode.Halt, 0, 0, 0));
	const f = createRaiserFunction("largePartialCopy", s.code, s.constants,
		0, 0, s.regClasses.length, s.regClasses);
	assert f.packed.length == s.code.length;
}

test "raiserPackedLegacy: legacy integer float conformance requires exact conversion" {
	for (const kind of [TypeKind.Float32, TypeKind.Float64]) {
		const scalar = primitive(kind);
		const t = record(["n"], [scalar]);
		for (const n of [3 as int64, -3 as int64, 16777216 as int64,
			1152921504606846976 as int64, -9223372036854775807 - 1]) {
			const s = createCompState();
			const layouts = createVmLayouts();
			const old = object(s, t, [value(s, raiserInt(n))], false);
			const rebuilt = emitPackedToLegacy(s, layouts,
				emitLegacyToPacked(s, layouts, legacy(old, t))).reg;
			const result = loadField(s, rebuilt, "n", scalar);
			drop(s, old);
			drop(s, rebuilt);
			const vm = run(s);
			assert vm.error == "", vm.error;
			assert vm.regs.slots[result] == floatBits(n as float64);
		}
		const inexact: int64[] = kind == TypeKind.Float32
			? [16777217, 9007199254740993, 9223372036854775807]
			: [9007199254740993, -9007199254740993, 9223372036854775807];
		for (const n of inexact) {
			const s = createCompState();
			const old = object(s, t, [value(s, raiserInt(n))], false);
			emitLegacyToPacked(s, createVmLayouts(), legacy(old, t));
			const vm = run(s);
			assert vm.error.includes(kind == TypeKind.Float32
				? "integer-to-float32 conversion" : "integer-to-float64 conversion"),
				vm.error;
		}
		const s = createCompState();
		const old = object(s, t, [value(s, raiserBool(true))], false);
		emitLegacyToPacked(s, createVmLayouts(), legacy(old, t));
		assert run(s).error.includes("invalid legacy carrier");
	}
}
