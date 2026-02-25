// Destructor Lifting — generate per-type _destroy and _copy function bodies
//
// Nim reference: liftdestructors.nim (fillBody dispatch per field type)
// Walks InterfaceDecl/ClassDecl nodes, looks up resolved Type in CheckerContext,
// generates FunctionDecl AST nodes for TypeName_destroy and TypeName_copy.
//
// Requires: CheckerContext threaded through TransformContext (Phase 2 type info).

import {
	Node, NodeKind, ProgramData, FunctionDeclData,
	InterfaceDeclData, ClassDeclData, ExportDeclData,
} from "../../ast/node";
import { TransformContext, NameSet, nameSetContains, nameSetAdd } from "../context";
import { makeIdent, makeBlock, makeExprStmt, makeCall, makeMember, makeAssign, makeFnDecl, syntheticToken } from "../util";
import { Type, TypeKind } from "../../checker/types";
import { lookupSymbol, SymbolKind } from "../../checker/symbol";
import { checkProgram } from "../../checker/checkPass";
import { sliceStr } from "../../utils/string";
import { test, check, testGroup } from "std/testing";
import { parseInput } from "../testUtil";

// ===== DRC-safe collector (Node[] is value type) =====

interface DeclCollector {
	decls: Node[];
}

// ===== Field Type Classification =====

function isPrimitiveKind(kind: TypeKind): boolean {
	return kind === TypeKind.Number
		|| kind === TypeKind.Boolean
		|| kind === TypeKind.Void
		|| kind === TypeKind.Null
		|| kind === TypeKind.Int32
		|| kind === TypeKind.Int64
		|| kind === TypeKind.Uint32
		|| kind === TypeKind.Float32
		|| kind === TypeKind.Float64
		|| kind === TypeKind.Enum
		|| kind === TypeKind.Never
		|| kind === TypeKind.Unknown
		|| kind === TypeKind.Error;
}

function isPointerType(fieldType: Type, ctx: TransformContext): boolean {
	if (fieldType.kind === TypeKind.Ref || fieldType.kind === TypeKind.Ptr) return true;
	if (fieldType.kind === TypeKind.Object) {
		if (fieldType.typeName === "") return false;
		const sym = lookupSymbol(ctx.checkerCtx.table, fieldType.typeName);
		if (sym === null) return false;
		return sym.symbolKind === SymbolKind.Interface || sym.symbolKind === SymbolKind.Class;
	}
	return false;
}

// Classify a field type for destroy dispatch.
// Returns: "none", "string_decref", "array_destroy", "array_string_destroy",
//          "array_ref_destroy", "interface_decref", "object_destroy"
function classifyForDestroy(fieldType: Type, ctx: TransformContext, visited: NameSet): string {
	return match (fieldType.kind) {
		TypeKind.String => "string_decref",
		TypeKind.Array => {
			const elem = fieldType.typeReturn;
			if (elem === null) return "array_destroy";
			if (isPrimitiveKind(elem.kind)) return "array_destroy";
			if (elem.kind === TypeKind.String) return "array_string_destroy";
			"array_ref_destroy"
		},
		TypeKind.Object => {
			if (isPointerType(fieldType, ctx)) return "interface_decref";
			// Value-type struct — needs TypeName_destroy if it has RC fields
			if (fieldType.typeName !== "" && typeNeedsHooksChecked(fieldType, ctx, visited)) {
				return "object_destroy";
			}
			"none"
		},
		TypeKind.Ref | TypeKind.Ptr => "interface_decref",
		TypeKind.TypeReference => {
			if (fieldType.typeName === "") return "none";
			if (nameSetContains(visited, fieldType.typeName)) return "none";
			nameSetAdd(visited, fieldType.typeName);
			const sym = lookupSymbol(ctx.checkerCtx.table, fieldType.typeName);
			if (sym === null) return "none";
			classifyForDestroy(sym.symbolType, ctx, visited)
		},
		_ => "none",
	};
}

// Classify a field type for copy dispatch.
// Returns: "none", "string_incref", "array_copy", "array_string_copy",
//          "array_ref_copy", "interface_incref", "object_copy"
function classifyForCopy(fieldType: Type, ctx: TransformContext, visited: NameSet): string {
	return match (fieldType.kind) {
		TypeKind.String => "string_incref",
		TypeKind.Array => {
			const elem = fieldType.typeReturn;
			if (elem === null) return "array_copy";
			if (isPrimitiveKind(elem.kind)) return "array_copy";
			if (elem.kind === TypeKind.String) return "array_string_copy";
			"array_ref_copy"
		},
		TypeKind.Object => {
			if (isPointerType(fieldType, ctx)) return "interface_incref";
			if (fieldType.typeName !== "" && typeNeedsHooksChecked(fieldType, ctx, visited)) {
				return "object_copy";
			}
			"none"
		},
		TypeKind.Ref | TypeKind.Ptr => "interface_incref",
		TypeKind.TypeReference => {
			if (fieldType.typeName === "") return "none";
			if (nameSetContains(visited, fieldType.typeName)) return "none";
			nameSetAdd(visited, fieldType.typeName);
			const sym = lookupSymbol(ctx.checkerCtx.table, fieldType.typeName);
			if (sym === null) return "none";
			classifyForCopy(sym.symbolType, ctx, visited)
		},
		_ => "none",
	};
}

// ===== Needs Hooks Check =====

function typeNeedsHooks(objType: Type, ctx: TransformContext): boolean {
	const visited: NameSet = { names: [] };
	return typeNeedsHooksChecked(objType, ctx, visited);
}

function typeNeedsHooksChecked(objType: Type, ctx: TransformContext, visited: NameSet): boolean {
	if (objType.kind !== TypeKind.Object) return false;
	if (objType.typeName !== "") {
		if (nameSetContains(visited, objType.typeName)) return false;
		nameSetAdd(visited, objType.typeName);
	}
	let i = 0;
	while (i < objType.typeChildren.length) {
		const action = classifyForDestroy(objType.typeChildren[i], ctx, visited);
		if (action !== "none") return true;
		i += 1;
	}
	return false;
}

// ===== Generate _destroy Function =====

function generateDestroy(typeName: string, objType: Type, ctx: TransformContext, loc: SourceLocation): Node {
	const bodyStmts: Node[] = [];

	// Iterate fields in REVERSE order (Nim pattern: dependencies destroyed first)
	let i = objType.typeNames.length;
	while (i > 0) {
		i -= 1;
		const fieldName = objType.typeNames[i];
		const fieldType = objType.typeChildren[i];
		const visited: NameSet = { names: [] };
		const action = classifyForDestroy(fieldType, ctx, visited);

		if (action === "none") continue;

		const selfField = makeMember(makeIdent("self", loc), fieldName, loc);
		const callName = match (action) {
			"string_decref" => "ms_string_decref",
			"array_destroy" => "ms_array_destroy",
			"array_string_destroy" => "ms_array_string_destroy",
			"array_ref_destroy" => "MS_ARRAY_REF_DESTROY",
			"interface_decref" => "ms_decref",
			"object_destroy" => fieldType.typeName + "_destroy",
			_ => "",
		};
		if (callName !== "") {
			bodyStmts.push(makeExprStmt(makeCall(makeIdent(callName, loc), [selfField], loc), loc));
		}
	}

	const body = makeBlock(bodyStmts, loc);
	return makeFnDecl(typeName + "_destroy", ["self"], [typeName], body, "", "void", loc);
}

// ===== Generate _copy Function =====

function generateCopy(typeName: string, objType: Type, ctx: TransformContext, loc: SourceLocation): Node {
	const bodyStmts: Node[] = [];

	let i = 0;
	while (i < objType.typeNames.length) {
		const fieldName = objType.typeNames[i];
		const fieldType = objType.typeChildren[i];
		const visited: NameSet = { names: [] };
		const action = classifyForCopy(fieldType, ctx, visited);

		const destField = makeMember(makeIdent("dest", loc), fieldName, loc);
		const srcField = makeMember(makeIdent("src", loc), fieldName, loc);

		if (action === "array_ref_copy" || action === "array_string_copy" || action === "array_copy") {
			// Arrays: use copy function instead of plain assign
			if (action === "array_ref_copy") {
				bodyStmts.push(makeExprStmt(makeCall(makeIdent("MS_ARRAY_REF_COPY", loc), [destField, srcField], loc), loc));
			} else if (action === "array_string_copy") {
				bodyStmts.push(makeExprStmt(makeCall(makeIdent("ms_array_string_copy", loc), [destField, srcField], loc), loc));
			} else {
				bodyStmts.push(makeExprStmt(makeCall(makeIdent("ms_array_copy", loc), [destField, srcField], loc), loc));
			}
		} else if (action === "object_copy") {
			// Value-type struct: use TypeName_copy
			const fnName = fieldType.typeName + "_copy";
			bodyStmts.push(makeExprStmt(makeCall(makeIdent(fnName, loc), [destField, srcField], loc), loc));
		} else {
			// All other types: plain assign first
			bodyStmts.push(makeExprStmt(makeAssign(destField, srcField, loc), loc));

			// Then incref if needed
			if (action === "string_incref") {
				const destField2 = makeMember(makeIdent("dest", loc), fieldName, loc);
				bodyStmts.push(makeExprStmt(makeCall(makeIdent("ms_string_incref", loc), [destField2], loc), loc));
			} else if (action === "interface_incref") {
				const destField2 = makeMember(makeIdent("dest", loc), fieldName, loc);
				bodyStmts.push(makeExprStmt(makeCall(makeIdent("ms_incref", loc), [destField2], loc), loc));
			}
		}

		i += 1;
	}

	const body = makeBlock(bodyStmts, loc);
	return makeFnDecl(typeName + "_copy", ["dest", "src"], [typeName, typeName], body, "", "void", loc);
}

// ===== Process Declarations =====

function processDecl(stmt: Node, ctx: TransformContext, collector: DeclCollector, generated: NameSet): void {
	match (stmt.kind) {
		NodeKind.InterfaceDecl => {
			const d = stmt.data as InterfaceDeclData;
			processType(d.interfaceName, ctx, collector, generated, stmt.location);
		},
		NodeKind.ClassDecl => {
			const d = stmt.data as ClassDeclData;
			processType(d.className, ctx, collector, generated, stmt.location);
		},
		NodeKind.ExportDecl => {
			const ed = stmt.data as ExportDeclData;
			processDecl(ed.exportedDecl, ctx, collector, generated);
		},
		_ => {},
	};
}

function processType(typeName: string, ctx: TransformContext, collector: DeclCollector, generated: NameSet, loc: SourceLocation): void {
	if (nameSetContains(generated, typeName)) return;
	nameSetAdd(generated, typeName);

	const sym = lookupSymbol(ctx.checkerCtx.table, typeName);
	if (sym === null) return;
	if (sym.symbolType.kind !== TypeKind.Object) return;

	const objType = sym.symbolType;
	if (!typeNeedsHooks(objType, ctx)) return;

	collector.decls.push(generateDestroy(typeName, objType, ctx, loc));
	collector.decls.push(generateCopy(typeName, objType, ctx, loc));
}

// ===== Main Entry Point =====

export function liftDestructors(program: Node, ctx: TransformContext): Node {
	if (ctx.checkerCtx === null) return program;

	const pd = program.data as ProgramData;
	const collector: DeclCollector = { decls: [] };
	const generated: NameSet = { names: [] };

	let i = 0;
	while (i < pd.programStmts.length) {
		processDecl(pd.programStmts[i], ctx, collector, generated);
		i += 1;
	}

	for (const decl of collector.decls) {
		pd.programStmts.push(decl);
	}

	return program;
}

// ===== Tests =====

// Test helper: run full checker pipeline then lift destructors
function liftWithChecker(input: string): Node {
	const pr = parseInput(input);
	if (!pr.ok) return pr.value;
	const checkerCtx = checkProgram(pr.value);
	const ctx: TransformContext = { tempCounter: 0, errors: [], fnDeclNames: [], checkerCtx };
	return liftDestructors(pr.value, ctx);
}

// Check if name ends with suffix (no indexOf/includes — DRC gotcha #8)
function nameEndsWith(name: string, suffix: string): boolean {
	if (name.length < suffix.length) return false;
	const tail = sliceStr(name, name.length - suffix.length, name.length);
	return tail === suffix;
}

function generatedFnCount(input: string): number {
	const prog = liftWithChecker(input);
	const pd = prog.data as ProgramData;
	let count = 0;
	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.FunctionDecl) {
			const d = stmt.data as FunctionDeclData;
			if (nameEndsWith(d.fnName, "_destroy") || nameEndsWith(d.fnName, "_copy")) {
				count += 1;
			}
		}
	}
	return count;
}

testGroup("Destructor Lifting", () => {
	test("primitive-only no hooks", () => {
		check(generatedFnCount("interface Point { x: number; y: number; }") === 0);
	});
	test("string field generates hooks", () => {
		check(generatedFnCount("interface Token { value: string; }") === 2);
	});
	test("array field generates hooks", () => {
		check(generatedFnCount("interface Data { items: number[]; }") === 2);
	});
	test("interface field generates hooks", () => {
		check(generatedFnCount("interface A { name: string; } interface B { a: A; }") === 4);
	});
	test("no duplicates", () => {
		check(generatedFnCount("interface A { name: string; } interface B { a1: A; a2: A; }") === 4);
	});
	test("exported interface", () => {
		check(generatedFnCount("export interface Token { value: string; }") === 2);
	});
	test("no interfaces passthrough", () => {
		check(generatedFnCount("const x = 1;") === 0);
	});
});
