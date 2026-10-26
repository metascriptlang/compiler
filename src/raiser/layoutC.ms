import { Type, TypeKind, SymbolKind } from "../ast/node";
import { createStruct, createPrimitive, createArray, createRef, createTuple, createUnion, createFunction, createEnum } from "../checker/types";
import { makeSymbol } from "../checker/symbol";
import { CheckerContext } from "../checker/context";
import { createAliveSet, CEmissionFacts, CSection, createCGen, sec, extract } from "../codegen/c/context";
import { getTypeDesc } from "../codegen/c/types";
import { mangleFieldName } from "../codegen/c/names";
import { cwd, execFileCapture } from "std/process";
import { writeFile, exists } from "std/fs";
import { MemKind, VmLayout, VmLayouts, createVmLayouts, vmLayoutOf, vmCellOf, CELL_HEADER_SIZE } from "./layout";

function declared(t: Type): Type {
	t.sym = makeSymbol(t.typeName, SymbolKind.Struct, t, false);
	return t;
}

function scalarWidth(kind: MemKind): number {
	return match (kind) {
		MemKind.Block => 0,
		MemKind.I8 | MemKind.U8 => 1,
		MemKind.I16 | MemKind.U16 => 2,
		MemKind.I32 | MemKind.U32 | MemKind.F32 => 4,
		MemKind.I64 | MemKind.U64 | MemKind.F64 | MemKind.Ptr => 8,
	};
}

function isInteger(kind: MemKind): boolean {
	return kind >= MemKind.I8 && kind <= MemKind.U64;
}

function isSigned(kind: MemKind): boolean {
	return kind >= MemKind.I8 && kind <= MemKind.I64;
}

function layoutAsserts(cType: string, layout: VmLayout): string {
	let out = `_Static_assert(sizeof(${cType}) == ${layout.size}, "${cType} size");\n`
		+ `_Static_assert(_Alignof(${cType}) == ${layout.align}, "${cType} align");\n`;
	for (const slot of layout.slots) {
		const member = mangleFieldName(slot.name);
		const read = `((${cType}*)0)->${member}`;
		out += `_Static_assert(offsetof(${cType}, ${member}) == ${slot.offset}, "${cType}.${member} offset");\n`;
		const width = scalarWidth(slot.kind);
		if (width > 0) out += `_Static_assert(sizeof(${read}) == ${width}, "${cType}.${member} width");\n`;
		if (isInteger(slot.kind)) out += `_Static_assert((((__typeof__(${read}))-1) < 0) == ${isSigned(slot.kind) ? 1 : 0}, "${cType}.${member} sign");\n`;
	}
	return out;
}

function emitted(types: Type[]): string[] {
	const g = createCGen(null as unknown as CheckerContext, "", createAliveSet(), new CEmissionFacts());
	const names: string[] = [];
	for (const t of types) names.push(getTypeDesc(g, t));
	const text = extract(sec(g, CSection.ForwardDecls)) + extract(sec(g, CSection.Types)) + extract(sec(g, CSection.SeqTypes));
	names.push(text);
	return names;
}

function compileC(source: string): string {
	const runtime = `${cwd()}/runtime`;
	if (!exists(`${runtime}/manual.h`)) return `internal: no runtime tree at ${runtime}`;
	const file = "/tmp/vmLayoutPin.c";
	if (!writeFile(file, source).ok) return `internal: cannot write ${file}`;
	const r = execFileCapture("cc", ["-std=c11", "-fsyntax-only", "-I", runtime, "-I", cwd(), file]);
	return r.ok ? "" : r.error.errorOutput + r.error.output + r.error.message;
}

function prelude(): string {
	return "#include <stddef.h>\n#include <stdint.h>\n#include \"manual.h\"\n";
}

function pin(types: Type[], cTypes: string[], layouts: VmLayout[]): string {
	const names = emitted(types);
	const text = names[names.length - 1];
	let asserts = "";
	for (let i = 0; i < layouts.length; i += 1) asserts += layoutAsserts(cTypes[i] == "" ? names[i] : cTypes[i], layouts[i]);
	return compileC(prelude() + text + asserts);
}

function aggregates(): Type[] {
	const int8 = createPrimitive(TypeKind.Int8);
	const int16 = createPrimitive(TypeKind.Int16);
	const int32 = createPrimitive(TypeKind.Int32);
	const num = createPrimitive(TypeKind.Number);
	const str = createPrimitive(TypeKind.String);
	const flag = createPrimitive(TypeKind.Boolean);
	const inner = declared(createStruct("Inner", ["a", "b"], [int8, num], true));
	const outer = declared(createStruct("Outer", ["x", "inner", "s", "flag"], [int32, inner, str, flag], true));
	const va = declared(createStruct("UA", ["p", "q"], [int8, num], true));
	const vb = declared(createStruct("UB", ["n"], [int16], true));
	const un = createUnion([va, vb]);
	const holder = declared(createStruct("Holder", ["k", "u", "z"], [int8, un, int8], true));
	const tuple = createTuple([int8, num, int32]);
	return [inner, outer, un, holder, tuple];
}

test "VmLayout of structs, a union, a union inside a struct and a tuple equals the C compiler's" {
	const types = aggregates();
	const layouts = createVmLayouts();
	const list: VmLayout[] = [];
	for (const t of types) list.push(vmLayoutOf(layouts, t));
	const names = emitted(types);
	const cTypes: string[] = [];
	for (let i = 0; i < types.length; i += 1) cTypes.push(`struct ${names[i]}`);
	assert pin(types, cTypes, list) == "", pin(types, cTypes, list);
	assert list[3].slots.length == 3 && list[3].slots[1].kind == MemKind.Block && list[1].slots[1].kind == MemKind.Block;
}

test "VmLayout of a string, an array, a closure and a class cell equals the C compiler's" {
	const num = createPrimitive(TypeKind.Number);
	const cell = createRef(declared(createStruct("Cell", ["n", "name", "flag"], [num, createPrimitive(TypeKind.String), createPrimitive(TypeKind.Int16)], false)));
	const types: Type[] = [createPrimitive(TypeKind.String), createArray(num), createFunction([num], ["x"], num), cell];
	const layouts = createVmLayouts();
	const list: VmLayout[] = [];
	for (let i = 0; i < 3; i += 1) list.push(vmLayoutOf(layouts, types[i]));
	const body = vmCellOf(layouts, cell);
	list.push(body);
	const names = emitted(types);
	const cTypes = [names[0], names[1], names[2], "struct Cell"];
	const verdict = pin(types, cTypes, list);
	assert verdict == "", verdict;
	const header = compileC(prelude() + `_Static_assert(sizeof(msRefHeader) == ${CELL_HEADER_SIZE} && ${body.header} == ${CELL_HEADER_SIZE}, "cell header");\n`);
	assert header == "", header;
}

test "a layout is built once per type and a type with no computable size is refused" {
	const layouts = createVmLayouts();
	const types = aggregates();
	assert vmLayoutOf(layouts, types[1]) === vmLayoutOf(layouts, types[1]);
	assert vmLayoutOf(layouts, types[1]) !== vmLayoutOf(layouts, types[3]);
	let refused = "";
	try { vmLayoutOf(layouts, createPrimitive(TypeKind.Void)); } catch (e) { refused = e.message; }
	assert refused.includes("no VM layout"), refused;
	let notClass = "";
	try { vmCellOf(layouts, types[1]); } catch (e) { notClass = e.message; }
	assert notClass.includes("not a class reference"), notClass;
}

test "two distinct Type objects of one shape share one layout entry" {
	const layouts = createVmLayouts();
	const first = aggregates();
	const second = aggregates();
	assert first[1] !== second[1] && first[3] !== second[3];
	assert vmLayoutOf(layouts, first[1]) === vmLayoutOf(layouts, second[1]);
	assert vmLayoutOf(layouts, first[3]) === vmLayoutOf(layouts, second[3]);
	assert vmLayoutOf(layouts, first[1]) !== vmLayoutOf(layouts, first[3]);
}
