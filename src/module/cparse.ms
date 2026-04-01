// C Header Parser — pure MetaScript string-based C header analysis
//
// Scans C header text for typedef structs and function prototypes,
// generates equivalent MetaScript extern declarations.
// Handles multi-line function declarations (joins continuation lines).

// ===== C Type → MetaScript Type Mapping =====

function cTypeToMs(cType: string): string {
	const t = cType.trim();
	return match (t) {
		// String types
		"msString" => "string",
		"const char*" | "char*" | "const char *" | "char *" => "cstring",
		// Fixed-width integers (from stdint.h)
		"int8_t" | "signed char" => "int8",
		"int16_t" | "short" | "short int" => "int16",
		"int32_t" | "int" => "int32",
		"int64_t" | "long long" | "long long int" => "int64",
		"uint8_t" | "unsigned char" => "uint8",
		"uint16_t" | "unsigned short" | "unsigned short int" => "uint16",
		"uint32_t" | "unsigned int" | "unsigned" => "uint32",
		"uint64_t" | "unsigned long long" | "unsigned long long int" => "uint64",
		// Platform-dependent integers — resolved at parse time (macOS/Linux = 64-bit)
		"long" | "long int" => "int64",
		"unsigned long" | "unsigned long int" => "uint64",
		"size_t" => "uint64",
		"ssize_t" => "int64",
		// Floats
		"float" => "float32",
		"double" => "number",
		// Other primitives
		"void" => "void",
		"bool" | "_Bool" | "msBool" | "MS_BOOL" => "boolean",
		"char" => "uint8",
		// Pointers
		_ when (t.endsWith("*")) => {
			// Extract base type: "FILE*" → "FILE", "const void *" → "const void"
			let base = t.slice(0, t.length - 1).trim();
			if (base.startsWith("const ")) base = base.slice(6, base.length).trim();
			// void* / const void* → unknown (opaque handle, Nim: pointer)
			if (base === "void") return "unknown";
			// Typed pointers: FILE* → Ptr<FILE>, WGPUDevice* → Ptr<WGPUDevice>
			return `Ptr<${base}>`;
		},
		_ => t,
	};
}

// ===== Main Parser =====

export function translateCHeader(source: string, importedNames: string[]): string {
	let result = "";
	let resultLines = 1;
	let pos = 0;
	let lastLinePos = 0;
	let lastLineNum = 1;

	while (pos < source.length) {
		while (pos < source.length && (source.charCodeAt(pos) <= 32)) pos = pos + 1;
		if (pos >= source.length) break;

		// Skip single-line comments
		if (pos + 1 < source.length && source.slice(pos, pos + 2) === "//") {
			while (pos < source.length && source.charCodeAt(pos) !== "\n".code) pos = pos + 1;
			continue;
		}
		// Skip block comments
		if (pos + 1 < source.length && source.slice(pos, pos + 2) === "/*") {
			pos = pos + 2;
			while (pos + 1 < source.length && source.slice(pos, pos + 2) !== "*/") pos = pos + 1;
			pos = pos + 2;
			continue;
		}
		// Skip preprocessor directives
		if (source.charCodeAt(pos) === "#".code) {
			while (pos < source.length && source.charCodeAt(pos) !== "\n".code) pos = pos + 1;
			continue;
		}

		// typedef struct { ... } Name;
		if (source.slice(pos, pos + 15) === "typedef struct ") {
			const braceStart = source.indexOf("{", pos);
			if (braceStart < 0) { pos = pos + 15; continue; }
			let depth = 1;
			let braceEnd = braceStart + 1;
			while (braceEnd < source.length && depth > 0) {
				if (source.charCodeAt(braceEnd) === "{".code) depth = depth + 1;
				if (source.charCodeAt(braceEnd) === "}".code) depth = depth - 1;
				braceEnd = braceEnd + 1;
			}
			let nameStart = braceEnd;
			while (nameStart < source.length && source.charCodeAt(nameStart) <= 32) nameStart = nameStart + 1;
			let nameEnd = nameStart;
			while (nameEnd < source.length && source.charCodeAt(nameEnd) > 32 && source.charCodeAt(nameEnd) !== ";".code) nameEnd = nameEnd + 1;
			const structName = source.slice(nameStart, nameEnd);

			if (structName.length > 0 && structName !== "{" && (importedNames.length === 0 || importedNames.indexOf(structName) >= 0)) {
				while (lastLinePos < pos) { if (source.charCodeAt(lastLinePos) === "\n".code) lastLineNum = lastLineNum + 1; lastLinePos = lastLinePos + 1; }
				while (resultLines < lastLineNum) { result = result + "\n"; resultLines = resultLines + 1; }
				const fieldsStr = source.slice(braceStart + 1, braceEnd - 1).trim();
				result = result + `export extern struct ${structName} {\n`; resultLines = resultLines + 1;
				let fPos = 0;
				while (fPos < fieldsStr.length) {
					while (fPos < fieldsStr.length && fieldsStr.charCodeAt(fPos) <= 32) fPos = fPos + 1;
					if (fPos >= fieldsStr.length) break;
					const semi = fieldsStr.indexOf(";", fPos);
					if (semi < 0) break;
					const fieldDecl = fieldsStr.slice(fPos, semi).trim();
					if (fieldDecl.length > 0) {
						const lastSpace = fieldDecl.lastIndexOf(" ");
						if (lastSpace > 0) {
							const fType = fieldDecl.slice(0, lastSpace).trim();
							const fName = fieldDecl.slice(lastSpace + 1, fieldDecl.length).trim();
							result = result + `\t${fName}: ${cTypeToMs(fType)};\n`; resultLines = resultLines + 1;
						}
					}
					fPos = semi + 1;
				}
				result = result + "}\n\n"; resultLines = resultLines + 2;
			}
			pos = source.indexOf(";", braceEnd);
			if (pos < 0) pos = source.length; else pos = pos + 1;
			continue;
		}

		// Function prototypes (with multi-line join)
		let lineEnd = source.indexOf("\n", pos);
		let line = source.slice(pos, lineEnd >= 0 ? lineEnd : source.length).trim();
		// Join multi-line declarations: if line has '(' but doesn't end with ';' or ') {', keep reading
		if (line.length > 0 && line.indexOf("(") > 0 && !line.endsWith(";") && !line.endsWith(") {")
			&& !line.startsWith("typedef") && !line.startsWith("#") && !line.startsWith("//")) {
			while (lineEnd >= 0 && !line.endsWith(";") && !line.endsWith(") {")) {
				const nextEnd = source.indexOf("\n", lineEnd + 1);
				const nextPart = source.slice(lineEnd + 1, nextEnd >= 0 ? nextEnd : source.length).trim();
				line = line + " " + nextPart;
				lineEnd = nextEnd;
			}
		}
		let funcLine = line;
		if (funcLine.startsWith("static inline ")) funcLine = funcLine.slice(14, funcLine.length);
		else if (funcLine.startsWith("static ")) funcLine = funcLine.slice(7, funcLine.length);
		else if (funcLine.startsWith("inline ")) funcLine = funcLine.slice(7, funcLine.length);
		else if (funcLine.startsWith("extern ")) funcLine = funcLine.slice(7, funcLine.length);

		if (funcLine.length > 0 && !funcLine.startsWith("typedef")
			&& !funcLine.startsWith("#") && !funcLine.startsWith("extern \"C\"")
			&& !funcLine.startsWith("{") && !funcLine.startsWith("}")
			&& funcLine.indexOf("(") > 0 && (funcLine.endsWith(";") || funcLine.endsWith(") {"))) {
			const hasBody = funcLine.endsWith(") {") || line.endsWith(") {");
			if (hasBody) funcLine = funcLine.slice(0, funcLine.length - 2) + ";";
			const parenOpen = funcLine.indexOf("(");
			const parenClose = funcLine.lastIndexOf(")");
			if (parenOpen > 0 && parenClose > parenOpen) {
				const beforeParen = funcLine.slice(0, parenOpen).trim();
				const lastSp = beforeParen.lastIndexOf(" ");
				if (lastSp > 0) {
					let retType = beforeParen.slice(0, lastSp).trim();
					let funcName = beforeParen.slice(lastSp + 1, beforeParen.length).trim();
					while (funcName.startsWith("*")) {
						funcName = funcName.slice(1, funcName.length);
						retType = retType + "*";
					}
					const paramsStr = funcLine.slice(parenOpen + 1, parenClose).trim();

					if (funcName.length > 0 && (importedNames.length === 0 || importedNames.indexOf(funcName) >= 0)) {
						while (lastLinePos < pos) { if (source.charCodeAt(lastLinePos) === "\n".code) lastLineNum = lastLineNum + 1; lastLinePos = lastLinePos + 1; }
						while (resultLines < lastLineNum) { result = result + "\n"; resultLines = resultLines + 1; }
						let msParams = "";
						if (paramsStr !== "void" && paramsStr.length > 0) {
							const params = paramsStr.split(",");
							let first = true;
							for (const p of params) {
								const param = p.trim();
								const pLastSp = param.lastIndexOf(" ");
								if (pLastSp > 0) {
									let pType = param.slice(0, pLastSp).trim();
									let pName = param.slice(pLastSp + 1, param.length).trim();
									while (pName.startsWith("*")) {
										pName = pName.slice(1, pName.length);
										pType = pType + "*";
									}
									if (!first) msParams = msParams + ", ";
									msParams = msParams + `${pName}: ${cTypeToMs(pType)}`;
									first = false;
								}
							}
						}
						result = result + `export extern function ${funcName}(${msParams}): ${cTypeToMs(retType)};\n`; resultLines = resultLines + 1;
					}
				}
			}
			if (hasBody) {
				let bodyDepth = 1;
				let bodyPos = source.indexOf("{", pos);
				if (bodyPos >= 0) {
					bodyPos = bodyPos + 1;
					while (bodyPos < source.length && bodyDepth > 0) {
						if (source.charCodeAt(bodyPos) === "{".code) bodyDepth = bodyDepth + 1;
						if (source.charCodeAt(bodyPos) === "}".code) bodyDepth = bodyDepth - 1;
						bodyPos = bodyPos + 1;
					}
					pos = bodyPos;
					continue;
				}
			}
		}
		pos = (lineEnd >= 0 ? lineEnd : source.length) + 1;
	}

	return result;
}

// ===== Tests =====

test "struct extraction" {
	const header = '#ifndef GUARD\n#define GUARD\n#include <stdio.h>\n\nstatic inline msString getFoo(void) {\n\treturn msStringFromCStr("foo");\n}\n\ntypedef struct {\n\tmsString name;\n\tint32_t age;\n} Person;\n\nstatic inline int32_t getAge(void) {\n\treturn 42;\n}\n\n#endif';
	const ms = translateCHeader(header, []);
	assert ms.indexOf("Person") >= 0;
	assert ms.indexOf("name: string") >= 0;
	assert ms.indexOf("age: int32") >= 0;
}

test "empty filter extracts all" {
	const header = 'typedef struct {\n\tmsString model;\n\tint32_t speed;\n} CpuInfo;\n\nstatic inline msString getName(void) {\n\treturn msStringFromCStr("cpu");\n}';
	const ms = translateCHeader(header, []);
	assert ms.indexOf("CpuInfo") >= 0;
	assert ms.indexOf("model: string") >= 0;
	assert ms.indexOf("getName") >= 0;
}

test "multi-line function declaration" {
	const header = 'void *create_thing(void *device, void *shader,\n    const char *name, int32_t count);';
	const ms = translateCHeader(header, []);
	assert ms.indexOf("create_thing") >= 0;
	assert ms.indexOf("name: string") >= 0;
	assert ms.indexOf("count: int32") >= 0;
}
