// C Header Module — ARO parsing + import-name synthesis for .h imports
//
// Provides two strategies for generating MetaScript source from C headers:
//   1. ARO (full): parses actual C header, extracts types/functions/enums
//   2. Synthesis (fallback): generates `export extern function NAME(): int64;`
//      from the import names found in the module graph
//
// `preprocessHeaders(graph)` runs strategy 1 with fallback to 2.
//
// Build prerequisites:
//   cd src/bindings/aro && zig build    (bridge.c auto-compiled by @include)

// ARO link directives are in bindings/aro/index.ms (resolved relative to that module's dir)

import {
	msAroParse, msAroError, msAroFree,
	msAroFuncCount, msAroFuncName, msAroFuncReturnType,
	msAroFuncParamCount, msAroFuncParamName, msAroFuncParamType,
	msAroFuncIsVariadic,
	msAroEnumCount, msAroEnumName, msAroEnumMemberCount, msAroEnumMemberName,
	msAroTypedefCount, msAroTypedefName, msAroTypedefTarget,
} from "../bindings/aro/index";
import { ModuleGraph, findModule } from "./graph";
import { sliceStr, trimStr, endsWith } from "../utils/string";
import { check } from "std/testing";

// ===== C Type → MetaScript Type Mapping =====

// Strip trailing C qualifiers (restrict, volatile, _Nonnull, etc.)
function stripQualifiers(t: string): string {
	let s = t;
	// Strip trailing qualifiers one at a time
	if (endsWith(s, " restrict")) { s = sliceStr(s, 0, s.length - 9); }
	if (endsWith(s, " volatile")) { s = sliceStr(s, 0, s.length - 9); }
	if (endsWith(s, " _Nonnull")) { s = sliceStr(s, 0, s.length - 9); }
	if (endsWith(s, " _Nullable")) { s = sliceStr(s, 0, s.length - 10); }
	if (endsWith(s, " __restrict")) { s = sliceStr(s, 0, s.length - 11); }
	return trimStr(s);
}

// Map a C type string to a MetaScript type annotation string.
export function mapCType(ctype: string): string {
	const t = stripQualifiers(trimStr(ctype));

	// Pointer types
	if (endsWith(t, "*")) {
		// Get base type (trim trailing * and spaces)
		let baseEnd = t.length - 1;
		const base = trimStr(sliceStr(t, 0, baseEnd));

		// char* / const char* → string
		if (base === "char" || base === "const char") return "string";
		// void* / const void* → int64 (opaque pointer)
		if (base === "void" || base === "const void") return "int64";
		// All other pointers → int64 (opaque)
		return "int64";
	}

	// void
	if (t === "void") return "void";

	// Boolean types
	if (t === "_Bool" || t === "bool" || t === "msBool") return "boolean";

	// MS runtime types
	if (t === "msString") return "string";

	// stdint fixed-width types
	if (t === "int8_t") return "int8";
	if (t === "int16_t") return "int16";
	if (t === "int32_t") return "int32";
	if (t === "int64_t") return "int64";
	if (t === "uint8_t") return "uint8";
	if (t === "uint16_t") return "uint16";
	if (t === "uint32_t") return "uint32";
	if (t === "uint64_t") return "uint64";

	// C primitive types
	if (t === "int") return "int32";
	if (t === "unsigned int" || t === "unsigned") return "uint32";
	if (t === "short" || t === "short int") return "int16";
	if (t === "unsigned short" || t === "unsigned short int") return "uint16";
	if (t === "long" || t === "long int") return "int64";
	if (t === "unsigned long" || t === "unsigned long int") return "uint64";
	if (t === "long long" || t === "long long int") return "int64";
	if (t === "unsigned long long" || t === "unsigned long long int") return "uint64";
	if (t === "float") return "float32";
	if (t === "double") return "float64";
	if (t === "char") return "int8";
	if (t === "signed char") return "int8";
	if (t === "unsigned char") return "uint8";

	// Size types
	if (t === "size_t") return "uint64";
	if (t === "ssize_t") return "int64";
	if (t === "intptr_t") return "int64";
	if (t === "uintptr_t") return "uint64";

	// Unknown/opaque type → int64 as fallback
	return "int64";
}

// ===== Synthetic Source Generator =====

// Generate a valid MetaScript parameter name (avoid reserved words)
function safeParamName(name: string): string {
	if (name === "" ) return "p";
	if (name === "type") return "argType";
	if (name === "function") return "fn";
	if (name === "class") return "cls";
	if (name === "interface") return "iface";
	if (name === "import") return "imp";
	if (name === "export") return "exp";
	if (name === "const") return "cnst";
	if (name === "let") return "letVal";
	if (name === "var") return "varVal";
	if (name === "return") return "ret";
	if (name === "enum") return "enumVal";
	return name;
}

// Parse a C header file and return synthetic MetaScript source.
// The source contains export extern function declarations for each C function.
export function parseCHeader(headerPath: string): string {
	const rc = msAroParse(headerPath);
	if (rc !== 0) {
		const errMsg = msAroError();
		msAroFree();
		return "// ARO parse error: " + errMsg + "\n";
	}

	let source = "// Auto-generated from C header: " + headerPath + "\n";

	// === Enums ===
	let ei = 0;
	const enumCount = msAroEnumCount();
	while (ei < enumCount) {
		const ename = msAroEnumName(ei as int32);
		if (ename.length > 0) {
			source = source + "\nexport enum " + ename + " {\n";
			let mi = 0;
			const memberCount = msAroEnumMemberCount(ei as int32);
			while (mi < memberCount) {
				const mname = msAroEnumMemberName(ei as int32, mi as int32);
				source = source + "\t" + mname + ",\n";
				mi = mi + 1;
			}
			source = source + "}\n";
		}
		ei = ei + 1;
	}

	// === Typedefs (as type aliases) ===
	let ti = 0;
	const typedefCount = msAroTypedefCount();
	while (ti < typedefCount) {
		const tname = msAroTypedefName(ti as int32);
		const ttarget = mapCType(msAroTypedefTarget(ti as int32));
		if (tname.length > 0) {
			source = source + "export type " + tname + " = " + ttarget + ";\n";
		}
		ti = ti + 1;
	}

	// === Functions ===
	let fi = 0;
	const funcCount = msAroFuncCount();
	while (fi < funcCount) {
		const fname = msAroFuncName(fi as int32);
		const retType = mapCType(msAroFuncReturnType(fi as int32));
		source = source + "export extern function " + fname + "(";

		let pi = 0;
		const paramCount = msAroFuncParamCount(fi as int32);
		while (pi < paramCount) {
			if (pi > 0) { source = source + ", "; }
			const pname = safeParamName(msAroFuncParamName(fi as int32, pi as int32));
			const ptype = mapCType(msAroFuncParamType(fi as int32, pi as int32));
			source = source + pname + ": " + ptype;
			pi = pi + 1;
		}

		source = source + "): " + retType + ";\n";
		fi = fi + 1;
	}

	msAroFree();
	return source;
}

// ===== Import-Name Synthesis (fallback when ARO unavailable) =====

// Generate synthetic MetaScript source for a C header module.
// Scans the module graph for all names imported from headerPath
// and generates `export extern function NAME(): int64;` for each.
// Actual C prototypes come from @include — this just satisfies the checker.
export function synthesizeHeaderSource(graph: ModuleGraph, headerPath: string): string {
	let source = "// Synthetic module for C header: " + headerPath + "\n";
	const emitted: string[] = [];

	for (const gmod of graph.modules) {
		for (const imp of gmod.imports) {
			if (imp.sourcePath === headerPath) {
				for (const name of imp.names) {
					let found = false;
					for (const e of emitted) {
						if (e === name) { found = true; }
					}
					if (!found) {
						source = source + "export extern function " + name + "(): int64;\n";
						emitted.push(name);
					}
				}
			}
		}
	}
	return source;
}

// ===== Header Pre-processing (ARO with synthesis fallback) =====

// Pre-process all C header modules in the graph.
// Tries ARO parsing first (type-aware); falls back to import-name synthesis.
export function preprocessHeaders(graph: ModuleGraph, verbose: boolean): void {
	for (const modPath of graph.loadOrder) {
		const hmod = findModule(graph, modPath);
		if (hmod === null || !hmod.isCHeader) continue;
		const aroSource = parseCHeader(hmod.path);
		if (aroSource.length > 60) {
			hmod.source = aroSource;
		} else {
			hmod.source = synthesizeHeaderSource(graph, hmod.path);
		}
	}
}

// ===== Tests =====
test "void" { check(mapCType("void") === "void"); }

test "int" { check(mapCType("int") === "int32"); }

test "unsigned int" { check(mapCType("unsigned int") === "uint32"); }

test "float" { check(mapCType("float") === "float32"); }

test "double" { check(mapCType("double") === "float64"); }

test "bool" { check(mapCType("bool") === "boolean"); }

test "_Bool" { check(mapCType("_Bool") === "boolean"); }

test "char" { check(mapCType("char") === "int8"); }

test "unsigned char" { check(mapCType("unsigned char") === "uint8"); }

test "int32_t" { check(mapCType("int32_t") === "int32"); }

test "uint64_t" { check(mapCType("uint64_t") === "uint64"); }

test "size_t" { check(mapCType("size_t") === "uint64"); }

test "char *" { check(mapCType("char *") === "string"); }

test "const char *" { check(mapCType("const char *") === "string"); }

test "void *" { check(mapCType("void *") === "int64"); }

test "int *" { check(mapCType("int *") === "int64"); }

test "msString" { check(mapCType("msString") === "string"); }

test "msBool" { check(mapCType("msBool") === "boolean"); }

test "short" { check(mapCType("short") === "int16"); }

test "long" { check(mapCType("long") === "int64"); }

test "long long" { check(mapCType("long long") === "int64"); }

test "whitespace trimmed" { check(mapCType("  int  ") === "int32"); }

test "safe param name type" { check(safeParamName("type") === "argType"); }

test "safe param name normal" { check(safeParamName("count") === "count"); }

test "safe param name empty" { check(safeParamName("") === "p"); }
