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
import { sliceStr, trimStr } from "../utils/string";

// ===== C Type → MetaScript Type Mapping =====

// Strip trailing C qualifiers (restrict, volatile, _Nonnull, etc.)
function stripQualifiers(t: string): string {
	let s = t;
	// Strip trailing qualifiers one at a time
	if (s.endsWith(" restrict")) { s = sliceStr(s, 0, s.length - 9); }
	if (s.endsWith(" volatile")) { s = sliceStr(s, 0, s.length - 9); }
	if (s.endsWith(" _Nonnull")) { s = sliceStr(s, 0, s.length - 9); }
	if (s.endsWith(" _Nullable")) { s = sliceStr(s, 0, s.length - 10); }
	if (s.endsWith(" __restrict")) { s = sliceStr(s, 0, s.length - 11); }
	return trimStr(s);
}

// Map a C type string to a MetaScript type annotation string.
export function mapCType(ctype: string): string {
	const t = stripQualifiers(trimStr(ctype));

	// Pointer types — can't be in match (endsWith check)
	if (t.endsWith("*")) {
		const base = trimStr(sliceStr(t, 0, t.length - 1));
		if (base === "char" || base === "const char") return "string";
		return "int64";
	}

	return match (t) {
		"void" => "void",
		"_Bool" | "bool" | "msBool" => "boolean",
		"msString" => "string",
		"int8_t" | "char" | "signed char" => "int8",
		"int16_t" | "short" | "short int" => "int16",
		"int32_t" | "int" => "int32",
		"int64_t" | "long" | "long int" | "long long" | "long long int" | "ssize_t" | "intptr_t" => "int64",
		"uint8_t" | "unsigned char" => "uint8",
		"uint16_t" | "unsigned short" | "unsigned short int" => "uint16",
		"uint32_t" | "unsigned int" | "unsigned" => "uint32",
		"uint64_t" | "unsigned long" | "unsigned long int" | "unsigned long long" | "unsigned long long int" | "size_t" | "uintptr_t" => "uint64",
		"float" => "float32",
		"double" => "float64",
		_ => "int64",
	};
}

// ===== Synthetic Source Generator =====

// Generate a valid MetaScript parameter name (avoid reserved words)
function safeParamName(name: string): string {
	return match (name) {
		"" => "p",
		"type" => "argType",
		"function" => "fn",
		"class" => "cls",
		"interface" => "iface",
		"import" => "imp",
		"export" => "exp",
		"const" => "cnst",
		"let" => "letVal",
		"var" => "varVal",
		"return" => "ret",
		"enum" => "enumVal",
		_ => name,
	};
}

// Parse a C header file and return synthetic MetaScript source.
// The source contains export extern function declarations for each C function.
export function parseCHeader(headerPath: string): string {
	const rc = msAroParse(headerPath);
	if (rc !== 0) {
		const errMsg = msAroError();
		msAroFree();
		return `// ARO parse error: ${errMsg}\n`;
	}

	let source = `// Auto-generated from C header: ${headerPath}\n`;

	// === Enums ===
	let ei = 0;
	const enumCount = msAroEnumCount();
	while (ei < enumCount) {
		const ename = msAroEnumName(ei as int32);
		if (ename.length > 0) {
			source = source + `\nexport enum ${ename} {\n`;
			let mi = 0;
			const memberCount = msAroEnumMemberCount(ei as int32);
			while (mi < memberCount) {
				const mname = msAroEnumMemberName(ei as int32, mi as int32);
				source = source + `\t${mname},\n`;
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
			source = source + `export type ${tname} = ${ttarget};\n`;
		}
		ti = ti + 1;
	}

	// === Functions ===
	let fi = 0;
	const funcCount = msAroFuncCount();
	while (fi < funcCount) {
		const fname = msAroFuncName(fi as int32);
		const retType = mapCType(msAroFuncReturnType(fi as int32));
		source = source + `export extern function ${fname}(`;

		let pi = 0;
		const paramCount = msAroFuncParamCount(fi as int32);
		while (pi < paramCount) {
			if (pi > 0) { source = source + ", "; }
			const pname = safeParamName(msAroFuncParamName(fi as int32, pi as int32));
			const ptype = mapCType(msAroFuncParamType(fi as int32, pi as int32));
			source = source + `${pname}: ${ptype}`;
			pi = pi + 1;
		}

		source = source + `): ${retType};\n`;
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
	let source = `// Synthetic module for C header: ${headerPath}\n`;
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
						source = source + `export extern function ${name}(): int64;\n`;
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
test "void" { assert mapCType("void") === "void"; }

test "int" { assert mapCType("int") === "int32"; }

test "unsigned int" { assert mapCType("unsigned int") === "uint32"; }

test "float" { assert mapCType("float") === "float32"; }

test "double" { assert mapCType("double") === "float64"; }

test "bool" { assert mapCType("bool") === "boolean"; }

test "_Bool" { assert mapCType("_Bool") === "boolean"; }

test "char" { assert mapCType("char") === "int8"; }

test "unsigned char" { assert mapCType("unsigned char") === "uint8"; }

test "int32_t" { assert mapCType("int32_t") === "int32"; }

test "uint64_t" { assert mapCType("uint64_t") === "uint64"; }

test "size_t" { assert mapCType("size_t") === "uint64"; }

test "char *" { assert mapCType("char *") === "string"; }

test "const char *" { assert mapCType("const char *") === "string"; }

test "void *" { assert mapCType("void *") === "int64"; }

test "int *" { assert mapCType("int *") === "int64"; }

test "msString" { assert mapCType("msString") === "string"; }

test "msBool" { assert mapCType("msBool") === "boolean"; }

test "short" { assert mapCType("short") === "int16"; }

test "long" { assert mapCType("long") === "int64"; }

test "long long" { assert mapCType("long long") === "int64"; }

test "whitespace trimmed" { assert mapCType("  int  ") === "int32"; }

test "safe param name type" { assert safeParamName("type") === "argType"; }

test "safe param name normal" { assert safeParamName("count") === "count"; }

test "safe param name empty" { assert safeParamName("") === "p"; }
