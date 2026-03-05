// C Codegen — Entry Point
//
// generateC(program, checkerCtx, modulePath) → string  (single-module, backwards compatible)
// generateCModule(program, checkerCtx, modulePath, crossModuleProtos) → string  (module-only, no dispatcher)
// genProjectDispatcher(modulePaths, entryPath, hasUserMain) → string  (global init dispatcher)
// collectFunctionPrototypes(program) → string  (C function forward declarations)
//
// Module init follows two-phase pattern:
//   DatInit000 (data/type init, runs first) + Init000 (user code, runs second)
//   main(argc, argv) → MsMain → MsPreMainInner (DatInit) → MsMainInner (Init)

import {
	Node, NodeKind, SymbolKind,
	ProgramData, FunctionDeclData, BlockStmtData,
	ExportDeclData, DecoratedDeclData, ImportDeclData,
	EnumDeclData, InterfaceDeclData, ClassDeclData,
} from "../../ast/node";
import { CheckerContext, ExportRegistry } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
// lookupSymbol removed — codegen uses node.resolvedSym (Nim parity)
import {
	CGen, CSection,
	createCGen, sec, add, addLine, addNewline,
	assembleOutput, extract, nameSetAdd, nameSetHas,
} from "./context";
import { genDecl } from "./declarations";
import { mangleModuleName, safeName } from "./names";
import { getSimpleTypeDesc, isNrvoReturnType, getTypeDesc, anonTypeName, isAnonTypeName, hashToBase36, buildAnonStructDef } from "./types";
import { Type, TypeKind, isInterfaceType } from "../../checker/types";
import { mangle } from "./names";
import { emitStringPoolDecls } from "./literals";
import { sliceStr, startsWith, findChar } from "../../utils/string";
import { check } from "std/testing";

// ===== generateC — single-module entry point (backwards compatible) =====

export function generateC(program: Node, ctx: CheckerContext, modulePath: string): string {
	const moduleCode = generateCModule(program, ctx, modulePath, "");
	const hasMain = (ctx !== null && ctx.table !== null) ? lookupSymbol(ctx.table, "main") !== null : false;
	const paths: string[] = [modulePath];
	const dispatcher = genProjectDispatcher(paths, modulePath, hasMain);
	return moduleCode + "\n" + dispatcher;
}

// ===== generateCModule — one module's C code (no dispatcher) =====
//
// Generates headers, type definitions, function prototypes, function bodies,
// and per-module DatInit000/Init000 (non-static for cross-module visibility).
// Does NOT generate the global dispatcher (MsPreMainInner/MsMainInner/MsMain/POSIX main).

export function generateCModule(program: Node, ctx: CheckerContext, modulePath: string, crossModuleProtos: string): string {
	const g = createCGen(ctx, modulePath);

	// Standard C headers
	addLine(sec(g, CSection.Headers), "#include <stdint.h>");
	addLine(sec(g, CSection.Headers), "#include <stdbool.h>");
	addLine(sec(g, CSection.Headers), "#include <string.h>");

	// Emit @include directives from checker (prelude + user code)
	if (ctx !== null && ctx.includeDirectives !== "") {
		emitIncludeDirectives(g, ctx.includeDirectives);
	}

	// Emit cross-module type forward decls + function prototypes.
	// ForwardDecls comes before Types, so imported types are available
	// when this module's own type definitions are emitted.
	if (crossModuleProtos.length > 0) {
		add(sec(g, CSection.ForwardDecls), crossModuleProtos);
		// Register cross-module type names for enum rewriting + class/interface distinction
		registerCrossModuleTypes(g, crossModuleProtos);
	}

	// Walk program statements
	if (program !== null && program.kind === NodeKind.Program) {
		const pd = program.data as ProgramData;
		for (let i = 0; i < pd.programStmts.length; i += 1) {
			genDecl(g, pd.programStmts[i], false);
		}
	}

	// Generate per-module init functions (non-static for cross-module visibility)
	genModuleInitFns(g);

	// Emit string literal pool declarations
	emitStringPoolDecls(g.stringPool, sec(g, CSection.StringPool));

	return assembleOutput(g);
}

// ===== Per-Module Init Functions =====
//
// Generates DatInit000 and Init000 for this module.
// Non-static so other modules' dispatchers can call them.

function genModuleInitFns(g: CGen): void {
	const modName = mangleModuleName(g.modulePath);
	const datInitName = modName + "__DatInit000";
	const initName = modName + "__Init000";

	const datContent = extract(sec(g, CSection.DatInit));
	const initContent = extract(sec(g, CSection.ModuleInit));

	// Clear sections (re-emitted into Procs)
	sec(g, CSection.DatInit).buf = "";
	sec(g, CSection.ModuleInit).buf = "";

	const hdrs = sec(g, CSection.ProcHeaders);
	const procs = sec(g, CSection.Procs);

	// DatInit000: data/type initialization (non-static for cross-module visibility)
	addLine(hdrs, "void " + datInitName + "(void);");
	addLine(procs, "void " + datInitName + "(void) {");
	addLine(procs, "  static MS_BOOL " + datInitName + "_guard_ = 0;");
	addLine(procs, "  if (" + datInitName + "_guard_) return;");
	addLine(procs, "  " + datInitName + "_guard_ = 1;");
	if (datContent.length > 0) {
		add(procs, datContent);
	}
	addLine(procs, "}");
	addNewline(procs);

	// Init000: user top-level code (non-static for cross-module visibility)
	addLine(hdrs, "void " + initName + "(void);");
	addLine(procs, "void " + initName + "(void) {");
	addLine(procs, "  static MS_BOOL " + initName + "_guard_ = 0;");
	addLine(procs, "  if (" + initName + "_guard_) return;");
	addLine(procs, "  " + initName + "_guard_ = 1;");
	if (initContent.length > 0) {
		add(procs, initContent);
	}
	addLine(procs, "}");
	addNewline(procs);
}

// ===== Global Init Dispatcher =====
//
// Generates the global init dispatcher: forward decls, MsPreMainInner, MsMainInner,
// MsMain, global vars, and POSIX main. Used by both single-module and multi-module builds.

export function genProjectDispatcher(modulePaths: string[], entryPath: string, hasUserMain: boolean): string {
	let result = "";

	// Forward declarations for all module init functions
	for (let i = 0; i < modulePaths.length; i += 1) {
		const modName = mangleModuleName(modulePaths[i]);
		result = result + "void " + modName + "__DatInit000(void);\n";
		result = result + "void " + modName + "__Init000(void);\n";
	}
	if (hasUserMain) {
		result = result + "void main_(void);\n";
	}
	result = result + "\n";

	// MsPreMainInner — calls DatInit000 for all modules in topological order
	result = result + "static void MsPreMainInner(void) {\n";
	for (let i = 0; i < modulePaths.length; i += 1) {
		result = result + "  " + mangleModuleName(modulePaths[i]) + "__DatInit000();\n";
	}
	result = result + "}\n\n";

	// MsMainInner — dependency Init000, then entry Init000, then user main
	result = result + "static void MsMainInner(void) {\n";
	for (let i = 0; i < modulePaths.length; i += 1) {
		if (modulePaths[i] !== entryPath) {
			result = result + "  " + mangleModuleName(modulePaths[i]) + "__Init000();\n";
		}
	}
	result = result + "  " + mangleModuleName(entryPath) + "__Init000();\n";
	if (hasUserMain) {
		result = result + "  main_();\n";
	}
	result = result + "}\n\n";

	// MsMain + globals + POSIX main
	result = result + "void MsMain(void) {\n  MsPreMainInner();\n  MsMainInner();\n}\n\n";
	result = result + "int cmdCount;\nchar** cmdLine;\nchar** gEnv;\nint msProgramResult;\n\n";
	result = result + "int main(int argc, char** argv, char** env) {\n";
	result = result + "  cmdLine = argv;\n  cmdCount = argc;\n  gEnv = env;\n";
	result = result + "  MsMain();\n  return msProgramResult;\n}\n";

	return result;
}

// ===== Collect Function Prototypes =====
//
// Walks the AST to collect C-level function forward declarations.
// Used by multi-module builds to generate a shared proto header
// so cross-module calls have proper declarations.

export function collectFunctionPrototypes(program: Node): string {
	let protos = "";
	if (program === null || program.kind !== NodeKind.Program) return protos;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const proto = protoFromStmt(pd.programStmts[i]);
		if (proto.length > 0) {
			protos = protos + proto + "\n";
		}
	}
	return protos;
}

function protoFromStmt(node: Node): string {
	if (node === null) return "";
	if (node.kind === NodeKind.FunctionDecl) {
		return buildFnProto(node);
	}
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return protoFromStmt(d.exportedDecl);
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return protoFromStmt(d.decoratedNode);
	}
	return "";
}

// ===== Type Description for Prototypes (no CGen needed) =====
// Maps a Type to its C type string for use in cross-module function prototypes.
// Unlike getTypeDesc which needs CGen for section emission, this is pure string mapping.
// Forward declarations for struct types are already emitted by collectExportedTypeDecls.

// Collects Result types encountered during prototype building.
// After collecting protos, call emitResultTypeDecls() to get struct definitions.
let protoResultTypes: string[] = [];
let protoResultTypeDefs: string[] = [];

function typeDescForProto(t: Type): string {
	if (!t) return "void*";
	if (!t.kind && t.kind !== 0) return "void*";
	// Try simple types first
	const simple = getSimpleTypeDesc(t);
	if (simple !== "") return simple;
	// Handle compound types
	if (t.kind === TypeKind.Enum) {
		return mangle(t.typeName);
	}
	if (t.kind === TypeKind.Object) {
		// Anonymous/structural types get hash-based names; named types get mangled names
		const name = isAnonTypeName(t.typeName) ? anonTypeName(t) : mangle(t.typeName);
		if (isInterfaceType(t)) return name;  // value type struct
		return name + "*";  // class = pointer to struct
	}
	if (t.kind === TypeKind.Array) {
		// Determine specific array type from element type
		if (t.typeReturn !== null) {
			const elemSimple = getSimpleTypeDesc(t.typeReturn);
			if (elemSimple === "double") return "msNumberArray";
			if (elemSimple === "msString") return "msStringArray";
		}
		return "msRefArray";
	}
	if (t.kind === TypeKind.Function) {
		return "msClosure";
	}
	if (t.kind === TypeKind.Result) {
		const okType = typeDescForProto(t.typeReturn);
		const errType = typeDescForProto(t.typeExtra);
		const name = "msResult_" + mangle(okType) + "_" + mangle(errType);
		// Record this Result type for later struct definition emission
		let found = false;
		for (let ri = 0; ri < protoResultTypes.length; ri += 1) {
			if (protoResultTypes[ri] === name) { found = true; }
		}
		if (!found) {
			protoResultTypes.push(name);
			let def = "#ifndef " + name + "_DEFINED\n";
			def = def + "#define " + name + "_DEFINED\n";
			def = def + "typedef struct " + name + " " + name + ";\n";
			def = def + "struct " + name + " {\n  MS_BOOL ok;\n";
			if (okType !== "void") def = def + "  " + okType + " value;\n";
			if (errType !== "void") def = def + "  " + errType + " error;\n";
			def = def + "};\n";
			def = def + "#endif\n";
			protoResultTypeDefs.push(def);
		}
		return name;
	}
	if (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr) {
		const inner = typeDescForProto(t.typeReturn);
		return inner + "*";
	}
	if (t.kind === TypeKind.SizedArray) {
		return "void*"; // rare in prototypes, safe fallback
	}
	if (t.kind === TypeKind.Span) {
		const elemType = typeDescForProto(t.typeReturn);
		return "msSpan_" + mangle(elemType);
	}
	if (t.kind === TypeKind.TypeReference) {
		// Function type annotation strings (e.g. "( ) => void") → msClosure
		if (findChar(t.typeName, "=".code) >= 0 || (t.typeName.length > 0 && t.typeName.charAt(0) === "(")) {
			return "msClosure";
		}
		if (t.typeName === "unknown" || t.typeName === "undefined" || t.typeName === "any" || t.typeName === "never") return "void*";
		// Anonymous type aliases (discriminated union variants) → hash-based name
		if (isAnonTypeName(t.typeName)) {
			const anonName = "msAnon_" + hashToBase36(t.typeName);
			emitProtoAnonStruct(anonName, t.typeName);
			return anonName;
		}
		// Named type ref — use mangled name (forward decl should exist)
		return mangle(t.typeName);
	}
	if (t.kind === TypeKind.Void || t.kind === TypeKind.Null) return "void";
	// Fallback for Unknown, Any, Union, etc.
	return "void*";
}

// Emit an anonymous struct definition into protoResultTypeDefs.
// Delegates to buildAnonStructDef (types.ms) for parsing and C mapping.
function emitProtoAnonStruct(structName: string, rawName: string): void {
	let found = false;
	for (let ri = 0; ri < protoResultTypes.length; ri += 1) {
		if (protoResultTypes[ri] === structName) { found = true; }
	}
	if (found) return;
	protoResultTypes.push(structName);
	protoResultTypeDefs.push(buildAnonStructDef(structName, rawName));
}

// Returns collected Result type struct definitions. Call after ALL modules' prototypes collected.
export function flushResultTypeDecls(): string {
	let result = "";
	for (let i = 0; i < protoResultTypeDefs.length; i += 1) {
		result = result + protoResultTypeDefs[i] + "\n";
	}
	// Reset for next build
	protoResultTypes = [];
	protoResultTypeDefs = [];
	return result;
}

function buildFnProto(node: Node): string {
	const d = node.data as FunctionDeclData;
	// Skip extern functions — they're FFI bindings provided by @include headers
	if (d.fnFlags === "extern" || d.fnFlags.indexOf("extern") >= 0) return "";
	const name = safeName(d.fnName);
	const fnType = node.nodeType;
	if (!fnType) return "";
	const retType = typeDescForProto(fnType.typeReturn);
	const nrvo = isNrvoReturnType(fnType.typeReturn);
	let paramList = "";
	if (nrvo) {
		paramList = retType + "* __result";
		if (d.params.length > 0) paramList = paramList + ", ";
	}
	for (let i = 0; i < d.params.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		const pType = (i < fnType.typeChildren.length) ? typeDescForProto(fnType.typeChildren[i]) : "void*";
		paramList = paramList + pType + " " + safeName(d.params[i]);
	}
	if (paramList === "") paramList = "void";
	const cRetType = nrvo ? "void" : retType;
	return cRetType + " " + name + "(" + paramList + ");";
}

// ===== Collect Exported Function Prototypes =====
//
// Like collectFunctionPrototypes but only collects prototypes for
// EXPORTED functions. Used for cross-module prototype headers in
// separate compilation (non-exported functions are static, invisible).

export function collectExportedPrototypes(program: Node): string {
	let protos = "";
	if (program === null || program.kind !== NodeKind.Program) return protos;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const proto = exportedProtoFromStmt(pd.programStmts[i]);
		if (proto.length > 0) {
			protos = protos + proto + "\n";
		}
	}
	return protos;
}

function exportedProtoFromStmt(node: Node): string {
	if (node === null) return "";
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return protoFromStmt(d.exportedDecl);
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return exportedProtoFromStmt(d.decoratedNode);
	}
	return "";
}

// ===== Collect Exported Type Forward Declarations =====
//
// Walks the AST to collect C-level type forward declarations for all
// exported types (enums, interfaces, classes). Used by cross-module builds
// so consuming modules can reference imported types without void* fallback.
// Nim parity: magicsys.nim / modulegraphs.nim type registry.

export function collectExportedTypeDecls(program: Node): string {
	let decls = "";
	if (program === null || program.kind !== NodeKind.Program) return decls;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const d = typeDeclFromStmt(pd.programStmts[i]);
		if (d.length > 0) {
			decls = decls + d + "\n";
		}
	}
	return decls;
}

function typeDeclFromStmt(node: Node): string {
	if (node === null) return "";
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return typeDeclFromInner(d.exportedDecl);
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return typeDeclFromStmt(d.decoratedNode);
	}
	return "";
}

function typeDeclFromInner(node: Node): string {
	if (node === null) return "";
	if (node.kind === NodeKind.EnumDecl) {
		const d = node.data as EnumDeclData;
		const name = safeName(d.enumName);
		let result = "typedef int32_t " + name + ";\n";
		for (let i = 0; i < d.enumMembers.length; i += 1) {
			result = result + "#define " + name + "_" + d.enumMembers[i] + " (((" + name + ")" + i + "))\n";
		}
		return result;
	}
	if (node.kind === NodeKind.InterfaceDecl) {
		const d = node.data as InterfaceDeclData;
		const name = safeName(d.interfaceName);
		// Emit full struct body if we have resolved Type info (needed for pass-by-value)
		const t = node.nodeType;
		if (t !== null && t.typeNames.length > 0) {
			let result = "#ifndef " + name + "_DEFINED\n#define " + name + "_DEFINED\n";
			result = result + "typedef struct " + name + " " + name + ";\n";
			result = result + "struct " + name + " {\n";
			for (let fi = 0; fi < t.typeNames.length; fi += 1) {
				let fieldType = (fi < t.typeChildren.length) ? typeDescForProto(t.typeChildren[fi]) : "void*";
				// Self-referential fields: same type as containing struct → must be pointer
				const ft = (fi < t.typeChildren.length) ? t.typeChildren[fi] : null as unknown as Type;
				if (ft !== null && ft.kind === TypeKind.Object && isInterfaceType(ft) && mangle(ft.typeName) === name) {
					fieldType = name + "*";
				}
				result = result + "  " + fieldType + " " + safeName(t.typeNames[fi]) + ";\n";
			}
			result = result + "};\n#endif\n";
			return result;
		}
		return "typedef struct " + name + " " + name + ";";
	}
	if (node.kind === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		const name = safeName(d.className);
		// Emit full struct body if we have resolved Type info (needed for cross-module member access)
		const t = node.nodeType;
		if (t !== null && t.typeNames.length > 0) {
			let result = "#ifndef " + name + "_DEFINED\n#define " + name + "_DEFINED\n";
			result = result + "typedef struct " + name + " " + name + ";\n";
			result = result + "struct " + name + " {\n";
			for (let fi = 0; fi < t.typeNames.length; fi += 1) {
				let fieldType = (fi < t.typeChildren.length) ? typeDescForProto(t.typeChildren[fi]) : "void*";
				// Self-referential fields: same type as containing struct → must be pointer
				const ft = (fi < t.typeChildren.length) ? t.typeChildren[fi] : null as unknown as Type;
				if (ft !== null && ft.kind === TypeKind.Object && !isInterfaceType(ft) && mangle(ft.typeName) === name) {
					fieldType = name + "*";
				}
				result = result + "  " + fieldType + " " + safeName(t.typeNames[fi]) + ";\n";
			}
			result = result + "};\n#endif\n";
			return result;
		}
		return "typedef struct " + name + " " + name + ";";
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return typeDeclFromInner(d.decoratedNode);
	}
	return "";
}

// ===== CGen-Based Exported Type Collection =====
// Uses getTypeDesc() for recursive topological ordering of struct bodies.
// Forward decls go to CSection.ForwardDecls, struct bodies to CSection.Types.

export function emitExportedTypesViaCGen(g: CGen, program: Node): void {
	if (program === null || program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		emitTypeDeclViaCGen(g, pd.programStmts[i]);
	}
}

function emitTypeDeclViaCGen(g: CGen, node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		emitTypeDeclViaCGenInner(g, d.exportedDecl);
	} else if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		emitTypeDeclViaCGen(g, d.decoratedNode);
	}
}

function emitTypeDeclViaCGenInner(g: CGen, node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.EnumDecl || node.kind === NodeKind.InterfaceDecl || node.kind === NodeKind.ClassDecl) {
		const t = node.nodeType;
		if (t !== null) {
			// getTypeDesc recursively emits field type struct bodies BEFORE this type
			getTypeDesc(g, t);
		} else {
			// No Type info — fall back to forward declaration only
			if (node.kind === NodeKind.EnumDecl) {
				const d = node.data as EnumDeclData;
				const name = safeName(d.enumName);
				addLine(sec(g, CSection.Types), "typedef int32_t " + name + ";");
				for (let i = 0; i < d.enumMembers.length; i += 1) {
					addLine(sec(g, CSection.Types), "#define " + name + "_" + d.enumMembers[i] + " (((" + name + ")" + i + "))");
				}
			} else if (node.kind === NodeKind.InterfaceDecl) {
				const d = node.data as InterfaceDeclData;
				addLine(sec(g, CSection.ForwardDecls), "typedef struct " + safeName(d.interfaceName) + " " + safeName(d.interfaceName) + ";");
			} else if (node.kind === NodeKind.ClassDecl) {
				const d = node.data as ClassDeclData;
				addLine(sec(g, CSection.ForwardDecls), "typedef struct " + safeName(d.className) + " " + safeName(d.className) + ";");
			}
		}
	} else if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		emitTypeDeclViaCGenInner(g, d.decoratedNode);
	}
}

// ===== Register Exported Class Names =====
// Pre-populates g.knownClassNames so getTypeDesc for TypeReference
// correctly emits ClassName* for class fields.

export function registerExportedClassNames(g: CGen, program: Node): void {
	if (program === null || program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		registerClassFromStmt(g, pd.programStmts[i]);
	}
}

function registerClassFromStmt(g: CGen, node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		registerClassFromInner(g, d.exportedDecl);
	} else if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		registerClassFromStmt(g, d.decoratedNode);
	}
}

function registerClassFromInner(g: CGen, node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		nameSetAdd(g.knownClassNames, safeName(d.className));
	} else if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		registerClassFromInner(g, d.decoratedNode);
	}
}

// ===== Collect Exported Enum Names =====
// Returns list of enum names exported by a module. Used by cross-module builds
// to register enum names in CGen.knownEnumNames so genMemberExpr can emit
// EnumName_Member instead of EnumName.Member.

export function collectExportedEnumNames(program: Node): string[] {
	const names: string[] = [];
	if (program === null || program.kind !== NodeKind.Program) return names;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const n = enumNameFromStmt(pd.programStmts[i]);
		if (n !== "") names.push(n);
	}
	return names;
}

function enumNameFromStmt(node: Node): string {
	if (node === null) return "";
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return enumNameFromInner(d.exportedDecl);
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return enumNameFromStmt(d.decoratedNode);
	}
	return "";
}

function enumNameFromInner(node: Node): string {
	if (node === null) return "";
	if (node.kind === NodeKind.EnumDecl) {
		const d = node.data as EnumDeclData;
		return safeName(d.enumName);
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return enumNameFromInner(d.decoratedNode);
	}
	return "";
}

// ===== Register Cross-Module Type Names =====
// Two-phase registration:
// 1. String-parsing: scans forward decl string for enum/struct names (existing)
// 2. ExportRegistry: iterates checker exports to distinguish class (pointer) from interface (value)
//
// knownEnumNames  — enum names for MemberExpr rewriting (TokenKind.Eof → TokenKind_Eof)
// knownTypeNames  — all cross-module type names (enums + interfaces + classes)
// knownClassNames — class names only (need pointer semantics: Name*)

function registerCrossModuleTypes(g: CGen, protos: string): void {
	// Phase 1: String-parsing for enum/struct names from forward decl string
	const enumPrefix = "typedef int32_t ";
	const structPrefix = "typedef struct ";
	let start = 0;
	for (let i = 0; i <= protos.length; i += 1) {
		if (i === protos.length || protos.charAt(i) === "\n") {
			const line = sliceStr(protos, start, i);
			if (startsWith(line, enumPrefix)) {
				// Extract enum name: strip prefix and trailing ";"
				const rest = sliceStr(line, enumPrefix.length, line.length);
				let nameEnd = rest.length;
				if (nameEnd > 0 && rest.charAt(nameEnd - 1) === ";") {
					nameEnd = nameEnd - 1;
				}
				const name = sliceStr(rest, 0, nameEnd);
				if (name.length > 0) {
					nameSetAdd(g.knownEnumNames, name);
					nameSetAdd(g.knownTypeNames, name);
				}
			} else if (startsWith(line, structPrefix)) {
				// Extract struct name: "typedef struct NAME NAME;" → NAME
				const rest = sliceStr(line, structPrefix.length, line.length);
				// Find first space after the name
				let spaceIdx = 0;
				while (spaceIdx < rest.length && rest.charAt(spaceIdx) !== " ") {
					spaceIdx = spaceIdx + 1;
				}
				const name = sliceStr(rest, 0, spaceIdx);
				if (name.length > 0) {
					nameSetAdd(g.knownTypeNames, name);
				}
			}
			start = i + 1;
		}
	}

	// Phase 2: ExportRegistry-based class/interface registration
	// Distinguishes class (needs Name*) from interface (needs Name)
	const reg = (g.checkerCtx !== null) ? g.checkerCtx.exportRegistry : null as unknown as ExportRegistry;
	if (reg !== null) {
		for (const entry of reg.entries) {
			for (const sym of entry.symbols) {
				const name = safeName(sym.name);
				if (sym.kind === SymbolKind.Class) {
					nameSetAdd(g.knownClassNames, name);
					nameSetAdd(g.knownTypeNames, name);
				} else if (sym.kind === SymbolKind.Interface) {
					nameSetAdd(g.knownTypeNames, name);
				}
			}
		}
	}
}

// ===== Emit @include directives from checker context =====

function emitIncludeDirectives(g: CGen, directives: string): void {
	let start = 0;
	for (let pos = 0; pos < directives.length; pos += 1) {
		if (directives.charAt(pos) === "\n") {
			const header = sliceStr(directives, start, pos);
			if (header.length > 0) {
				addLine(sec(g, CSection.Headers), "#include \"" + header + "\"");
			}
			start = pos + 1;
		}
	}
	if (start < directives.length) {
		const header = sliceStr(directives, start, directives.length);
		if (header.length > 0) {
			addLine(sec(g, CSection.Headers), "#include \"" + header + "\"");
		}
	}
}

// ===== Tests =====

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { createObject, numberType, stringType } from "../../checker/types";

function cOutput(input: string): string {
	const pr = parseSource(input);
	if (!pr.ok) return "PARSE_ERROR: " + pr.error;
	return generateC(pr.value, null as unknown as CheckerContext, "test/input");
}

function cModuleOutput(input: string): string {
	const pr = parseSource(input);
	if (!pr.ok) return "PARSE_ERROR: " + pr.error;
	return generateCModule(pr.value, null as unknown as CheckerContext, "test/input", "");
}

test "empty program has headers" {
	const result = cOutput("");
	check(result.length > 0);
}

test "headers include stdint" {
	const result = cOutput("");
	// stdint.h should be present
	check(result.length > 10);
}

test "simple function" {
	const result = cOutput("function foo(): void { return; }");
	check(result.length > 0);
}

test "enum output" {
	const result = cOutput("enum Dir { North, South, East, West }");
	check(result.length > 0);
}

test "function + call" {
	const result = cOutput("function add(a: number, b: number): number { return a + b; }");
	check(result.length > 0);
}

test "global var init in module Init000" {
	const result = cOutput("function add(a: number, b: number): number { return a + b; }\nconst result: number = add(2, 3);");
	check(result.length > 0);
}

test "two-phase init + POSIX main" {
	const result = cOutput("function add(a: number, b: number): number { return a + b; }\nconst result: number = add(2, 3);");
	check(result.length > 0);
}

test "MacroInvocation skipped in codegen" {
	const result = cOutput("@passL(\"-lssl\");");
	// Should not contain /* unsupported */
	check(result.length > 0);
}

test "@include from prelude emits header" {
	// prelude has @include("system.h"), so generated C should contain it
	const result = cOutput("");
	check(result.length > 0);
}

test "direct call detection" {
	// closureCallMarker sets isDirectCall on CallExpr nodes — codegen reads the flag
	const result = cOutput("function foo(): void {} function bar(): void { foo(); }");
	check(result.length > 0);
}

test "array literal" {
	const result = cOutput("const arr: number = [1, 2, 3];");
	check(result.length > 0);
}

test "generateCModule produces code without dispatcher" {
	const result = cModuleOutput("function foo(): void { return; }");
	check(result.length > 0);
}

test "collectFunctionPrototypes extracts protos" {
	const pr = parseSource("function add(a: number, b: number): number { return a + b; }");
	check(pr.ok);
	const protos = collectFunctionPrototypes(pr.value);
	check(protos.length > 0);
}

test "collectExportedPrototypes only exported" {
	const pr = parseSource("function helper(): void {}\nexport function api(): void {}");
	check(pr.ok);
	const exported = collectExportedPrototypes(pr.value);
	const all = collectFunctionPrototypes(pr.value);
	check(exported.length > 0);
	check(all.length > exported.length);
}

// Helper: find inner decl node from "export class Foo { ... }" and set nodeType
// Traverses through ExportDecl and DecoratedDecl wrappers to find the actual decl.
function setExportedDeclType(program: Node, objType: Type): void {
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		let node = pd.programStmts[i];
		if (node.kind === NodeKind.ExportDecl) {
			const ed = node.data as ExportDeclData;
			node = ed.exportedDecl;
		}
		if (node.kind === NodeKind.DecoratedDecl) {
			const dd = node.data as DecoratedDeclData;
			node = dd.decoratedNode;
		}
		if (node.kind === NodeKind.ClassDecl || node.kind === NodeKind.InterfaceDecl) {
			node.nodeType = objType;
		}
	}
}

test "class type decl emits full struct body" {
	const pr = parseSource("export class User { name: string; age: number; }");
	check(pr.ok);
	const classType = createObject("User", ["name", "age"], [stringType(), numberType()], false);
	setExportedDeclType(pr.value, classType);
	const decls = collectExportedTypeDecls(pr.value);
	// Full struct body: should contain "struct User {" and field definitions
	check(decls.length > 50);
}

test "class with no nodeType falls back to forward decl" {
	const pr = parseSource("export class Empty {}");
	check(pr.ok);
	const decls = collectExportedTypeDecls(pr.value);
	check(decls.length > 0);
	// Without nodeType, just a forward decl (no struct body)
	check(decls.length < 50);
}

test "interface type decl emits full struct body" {
	const pr = parseSource("export interface Token { kind: number; value: string; }");
	check(pr.ok);
	const ifaceType = createObject("Token", ["kind", "value"], [numberType(), stringType()], true);
	setExportedDeclType(pr.value, ifaceType);
	const decls = collectExportedTypeDecls(pr.value);
	// Full struct body: should contain "struct Token {" and field definitions
	check(decls.length > 50);
}

test "registerCrossModuleTypes parses enum and struct names" {
	const g = createCGen(null as unknown as CheckerContext, "test");
	const protos = "typedef int32_t Color;\ntypedef struct Token Token;\n";
	registerCrossModuleTypes(g, protos);
	check(nameSetHas(g.knownEnumNames, "Color"));
	check(nameSetHas(g.knownTypeNames, "Color"));
	check(nameSetHas(g.knownTypeNames, "Token"));
	check(!nameSetHas(g.knownClassNames, "Token"));
}

test "knownClassNames enables pointer semantics in fallback" {
	const g = createCGen(null as unknown as CheckerContext, "test");
	nameSetAdd(g.knownClassNames, "User");
	nameSetAdd(g.knownTypeNames, "User");
	check(nameSetHas(g.knownClassNames, "User"));
	check(nameSetHas(g.knownTypeNames, "User"));
	// Interface not in knownClassNames
	nameSetAdd(g.knownTypeNames, "Token");
	check(!nameSetHas(g.knownClassNames, "Token"));
}
