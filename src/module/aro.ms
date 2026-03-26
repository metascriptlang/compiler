// C Header Module — Native backend (ARO FFI)
//
// Parses C headers via ARO (Zig C parser) and generates MetaScript
// extern declarations for functions, structs, enums, and typedefs.
//
// Build prerequisites:
//   cd src/bindings/aro && zig build
//
// ARO link directives are in bindings/aro/index.ms (resolved relative to that module's dir)

import {
	msAroAddIncludeDir,
	msAroParse, msAroError, msAroFree,
	msAroFuncCount, msAroFuncName, msAroFuncReturnType,
	msAroFuncParamCount, msAroFuncParamName, msAroFuncParamType,
	msAroFuncIsVariadic,
	msAroStructCount, msAroStructName, msAroStructIsUnion,
	msAroStructFieldCount, msAroStructFieldName, msAroStructFieldType,
	msAroEnumCount, msAroEnumName, msAroEnumMemberCount, msAroEnumMemberName,
	msAroTypedefCount, msAroTypedefName, msAroTypedefTarget,
} from "../bindings/aro/index";
import { mapCType, safeParamName } from "./util";
// (utils/string imports removed — using native .slice/.trim)

// Register ARO builtin include dir (stdint.h, stddef.h, etc.)
// Must be absolute — CWD may be any project dir, not the recompiler root.
let _aroInitDone = false;
function ensureAroInit(): void {
	if (_aroInitDone) return;
	_aroInitDone = true;
	// Resolve absolute path: this module is src/module/aro.ms
	// ARO headers are at src/bindings/aro/zig-out/include (sibling path)
	// Use __dirname which resolves to the module's directory at compile time
	msAroAddIncludeDir(__dirname + "/../bindings/aro/zig-out/include");
}

// Parse a C header file and return synthetic MetaScript source.
// The source contains export extern function declarations for each C function.
export function parseCHeader(headerPath: string): string {
	ensureAroInit();
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

	// === Structs ===
	let si = 0;
	const structCount = msAroStructCount();
	while (si < structCount) {
		const sname = msAroStructName(si as int32);
		if (sname.length > 0) {
			const keyword = msAroStructIsUnion(si as int32) !== 0 ? "union" : "struct";
			source = source + `\nexport extern struct ${sname} {\n`;
			let sfi = 0;
			const fieldCount = msAroStructFieldCount(si as int32);
			while (sfi < fieldCount) {
				const fname = msAroStructFieldName(si as int32, sfi as int32);
				const ftype = mapCType(msAroStructFieldType(si as int32, sfi as int32));
				source = source + `\t${fname}: ${ftype};\n`;
				sfi = sfi + 1;
			}
			source = source + "}\n";
		}
		si = si + 1;
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

// Tests for mapCType/safeParamName are in util.ms
