import { BoundaryCallback, BoundaryFunction, BoundaryKind, BoundaryLeaf, BoundaryMode, BoundaryParam, leafLiteral, msTypeOf, signatureLetter, unwiredKind } from "./manifest";

const REGISTRY = "Module['msb']";

export interface WasmEntry {
	source: string;
	exportedFunctions: string[];
	jsLibrary: string;
	runtimeMethods: string[];
}

function valueTypeOf(kind: BoundaryKind): string {
	if (kind == BoundaryKind.Void) unwiredKind(kind, "value type");
	return msTypeOf(kind);
}

function wireMsType(letter: string): string {
	switch (letter) {
		case "i": return "int32";
		case "j": return "int64";
		case "f": return "float32";
		case "d": return "float64";
		case "v": return "void";
		default: throw new Error("internal: unknown callback signature letter " + letter);
	}
}

function wireCType(letter: string): string {
	switch (letter) {
		case "i": return "int32_t";
		case "j": return "int64_t";
		case "f": return "float";
		case "d": return "double";
		case "v": return "void";
		default: throw new Error("internal: unknown callback signature letter " + letter);
	}
}

function toWire(kind: BoundaryKind, expr: string): string {
	const own = valueTypeOf(kind);
	if (kind == BoundaryKind.Bool) return `(${expr} ? 1 : 0)`;
	const wire = wireMsType(signatureLetter(kind));
	return own == wire ? expr : `(${expr} as ${wire})`;
}

function fromWire(kind: BoundaryKind, expr: string): string {
	const own = valueTypeOf(kind);
	if (kind == BoundaryKind.Bool) return `(${expr} != 0)`;
	const wire = wireMsType(signatureLetter(kind));
	return own == wire ? expr : `(${expr} as ${own})`;
}

function wireNames(i: int32, letter: string): string[] {
	if (letter == "s" || letter == "p") return [`a${i}p`, `a${i}l`];
	return [`a${i}`];
}

function importLines(name: string, letters: string, result: string, withId: boolean): string[] {
	const cParams: string[] = withId ? ["int32_t id"] : [];
	const msParams: string[] = withId ? ["id: int32"] : [];
	for (let i = 0; i < letters.length; i += 1) {
		const l = letters.slice(i, i + 1);
		const names = wireNames(i, l);
		if (names.length == 2) {
			cParams.push(`uint32_t ${names[0]}, int32_t ${names[1]}`);
			msParams.push(`${names[0]}: uint32, ${names[1]}: int32`);
			continue;
		}
		cParams.push(`${wireCType(l)} ${names[0]}`);
		msParams.push(`${names[0]}: ${wireMsType(l)}`);
	}
	const attr = `__attribute__((import_module(\\"env\\"), import_name(\\"${name}\\")))`;
	return [
		`@emit("${attr} ${wireCType(result)} ${name}(${cParams.length == 0 ? "void" : cParams.join(", ")});");`,
		`extern function ${name}(${msParams.join(", ")}): ${wireMsType(result)} from "${name}";`,
	];
}

function callbackLines(cb: BoundaryCallback): string[] {
	if (cb.result == BoundaryKind.String || cb.result == BoundaryKind.Span) unwiredKind(cb.result, "callback result letter");
	return importLines("msb_cb_" + cb.signature, cb.signature.slice(2), cb.signature.slice(0, 1), true);
}

function callbackImportJs(signature: string): string {
	const letters = signature.slice(2);
	const wire: string[] = [];
	for (let i = 0; i < letters.length; i += 1) {
		for (const n of wireNames(i, letters.slice(i, i + 1))) wire.push(n);
	}
	return guardedImportJs(`msb_cb_${signature}`, ["id", ...wire], `${REGISTRY}.cb(id)(${wire.join(", ")})`);
}

function leafLetters(leaves: BoundaryLeaf[]): string {
	let letters = "";
	for (const leaf of leaves) letters += (leaf.nullable ? "i" : "") + signatureLetter(leaf.kind);
	return letters;
}

function zeroOf(kind: BoundaryKind): string {
	return kind == BoundaryKind.Bool ? "false" : "0";
}

function orMaybe(flag: string, value: string): string {
	return `(${flag} != 0 ? ${value} : null)`;
}

function vecFromLines(kind: BoundaryKind): string[] {
	const t = valueTypeOf(kind);
	return [
		`function msbVecFrom_${t}(ptr: uint32, len: int32): Vec<${t}> {`,
		`\tlet out: Vec<${t}> = [];`,
		`\tfor (const x of (ptr as uint64 as Ptr<${t}>)[0..len]) out.push(x);`,
		"\treturn out;",
		"}",
	];
}

function closureOf(cb: BoundaryCallback, idName: string): string {
	const params = cb.params;
	let sig = "";
	let args = idName;
	for (let i = 0; i < params.length; i += 1) {
		if (i > 0) sig += ", ";
		const nullable = cb.nullables[i];
		if (params[i] == BoundaryKind.String) {
			if (nullable) {
				sig += `a${i}: string | null`;
				args += `, (a${i} != null ? 1 : 0), (a${i} != null ? msbStrPtr(a${i}) : 0), (a${i} != null ? a${i}.asBytes().length : 0)`;
				continue;
			}
			sig += `a${i}: string`;
			args += `, msbStrPtr(a${i}), a${i}.asBytes().length`;
			continue;
		}
		if (params[i] == BoundaryKind.Span) {
			const t = valueTypeOf(cb.elements[i]);
			const ptr = cb.modes[i] == BoundaryMode.Shared ? `Ptr<${t}>` : `Readonly<Ptr<${t}>>`;
			sig += `a${i}: ${cb.modes[i] == BoundaryMode.Shared ? `Span<${t}>` : `Readonly<Span<${t}>>`}`;
			args += `, (a${i}.length == 0 ? 0 : a${i} as ${ptr} as uint64 as uint32), a${i}.length as int32`;
			continue;
		}
		if (nullable) {
			sig += `a${i}: ${valueTypeOf(params[i])} | null`;
			args += `, (a${i} != null ? 1 : 0), ` + toWire(params[i], `(a${i} ?? ${zeroOf(params[i])})`);
			continue;
		}
		sig += `a${i}: ${valueTypeOf(params[i])}`;
		args += ", " + toWire(params[i], `a${i}`);
	}
	const call = `msb_cb_${cb.signature}(${args})`;
	if (cb.result == BoundaryKind.Void) return `(${sig}): void => { ${call}; }`;
	return `(${sig}): ${msTypeOf(cb.result)} => ${fromWire(cb.result, call)}`;
}

function stringHelperLines(): string[] {
	return [
		"extern function msStringNew(data: cstring, length: int64): string;",
		"extern function msStringAdoptMalloced(block: uint64, length: int64): string;",
		"function msbStrFrom(ptr: uint32, len: int32): string {",
		"\treturn msStringNew(ptr as uint64 as Ptr<uint8> as cstring, len as int64);",
		"}",
		"function msbStrAdopt(ptr: uint32, len: int32): string {",
		"\treturn msStringAdoptMalloced(ptr as uint64, len as int64);",
		"}",
		"function msbStrPtr(s: string): uint32 {",
		"\treturn (s as cstring) as Ptr<uint8> as uint64 as uint32;",
		"}",
	];
}

function takenResult(f: BoundaryFunction, call: string, sig: string, take: string): string[] {
	const lines = [
		`@exportName("${f.exportSymbol}")`,
		`export function ${f.exportSymbol}(${sig}): void {`,
		`\tconst r = ${call};`,
	];
	if (f.resultNullable) {
		lines.push("\tif (r != null) {");
		lines.push("\t\t" + take);
		lines.push("\t}");
	} else {
		lines.push("\t" + take);
	}
	lines.push("}");
	return lines;
}

function wrapperLines(f: BoundaryFunction, alias: string): string[] {
	const sigs: string[] = [];
	const argList: string[] = [];
	for (let i = 0; i < f.params.length; i += 1) {
		const p: BoundaryParam = f.params[i];
		const some = `${p.name}Some`;
		if (p.nullable) sigs.push(`${some}: int32`);
		const present = (value: string): string => p.nullable ? orMaybe(some, value) : value;
		if (p.kind == BoundaryKind.String) {
			sigs.push(`${p.name}Ptr: uint32, ${p.name}Len: int32`);
			argList.push(present(`msbStrAdopt(${p.name}Ptr, ${p.name}Len)`));
		} else if (p.kind == BoundaryKind.Callback) {
			sigs.push(`${p.name}: int32`);
			argList.push(closureOf(p.callback!, p.name));
		} else if (p.kind == BoundaryKind.Struct) {
			const values: string[] = [];
			for (let j = 0; j < p.leaves.length; j += 1) {
				const leaf = `${p.name}_${j}`;
				const leafSome = `${leaf}Some`;
				const kind = p.leaves[j].kind;
				if (p.leaves[j].nullable) sigs.push(`${leafSome}: int32`);
				let value = leaf;
				if (kind == BoundaryKind.String) {
					sigs.push(`${leaf}Ptr: uint32, ${leaf}Len: int32`);
					value = `msbStrAdopt(${leaf}Ptr, ${leaf}Len)`;
				} else {
					sigs.push(`${leaf}: ${valueTypeOf(kind)}`);
				}
				values.push(p.leaves[j].nullable ? orMaybe(leafSome, value) : value);
			}
			argList.push(present(leafLiteral(p.leaves, values, 0)));
		} else if (p.kind == BoundaryKind.Vec) {
			sigs.push(`${p.name}Ptr: uint32, ${p.name}Len: int32`);
			argList.push(present(`msbVecFrom_${valueTypeOf(p.element)}(${p.name}Ptr, ${p.name}Len)`));
		} else if (p.kind == BoundaryKind.Span) {
			sigs.push(`${p.name}Ptr: uint32, ${p.name}Len: int32`);
			argList.push(`(${p.name}Ptr as uint64 as Ptr<${valueTypeOf(p.element)}>)[0..${p.name}Len]`);
		} else {
			sigs.push(`${p.name}: ${valueTypeOf(p.kind)}`);
			argList.push(present(p.name));
		}
	}
	const sig = sigs.join(", ");
	const call = `${alias}(${argList.join(", ")})`;
	if (f.result == BoundaryKind.Struct) {
		const wires: string[] = [];
		for (const leaf of f.resultLeaves) {
			const value = `r.${leaf.path.join(".")}`;
			if (leaf.nullable) wires.push(`(${value} != null ? 1 : 0)`);
			if (leaf.kind == BoundaryKind.String && leaf.nullable) {
				wires.push(`(${value} != null ? msbStrPtr(${value}) : 0), (${value} != null ? ${value}.asBytes().length : 0)`);
			} else if (leaf.kind == BoundaryKind.String) {
				wires.push(`msbStrPtr(${value}), ${value}.asBytes().length`);
			} else {
				wires.push(toWire(leaf.kind, leaf.nullable ? `(${value} ?? ${zeroOf(leaf.kind)})` : value));
			}
		}
		return takenResult(f, call, sig, `msb_rs_${leafLetters(f.resultLeaves)}(${wires.join(", ")});`);
	}
	if (f.result == BoundaryKind.Vec) {
		const t = valueTypeOf(f.resultElement);
		return takenResult(f, call, sig, `msb_rv((r as Span<${t}>) as Ptr<void> as uint64 as int32, r.length as int32);`);
	}
	if (f.result == BoundaryKind.String) {
		if (f.resultNullable) return takenResult(f, call, sig, "msb_rs_s(msbStrPtr(r), r.asBytes().length);");
		return [
			`@exportName("${f.exportSymbol}")`,
			`export function ${f.exportSymbol}(${sig}): void {`,
			`\tconst r = ${call};`,
			"\tmsb_rs_s(msbStrPtr(r), r.asBytes().length);",
			"}",
		];
	}
	if (f.resultNullable) {
		return [
			`@exportName("${f.exportSymbol}")`,
			`export function ${f.exportSymbol}(${sig}): ${msTypeOf(f.result)} {`,
			`\tconst r = ${call};`,
			"\tmsbRetSome = r != null ? 1 : 0;",
			`\treturn r ?? ${zeroOf(f.result)};`,
			"}",
		];
	}
	return [
		`@exportName("${f.exportSymbol}")`,
		`export function ${f.exportSymbol}(${sig}): ${msTypeOf(f.result)} {`,
		f.result == BoundaryKind.Void ? `\t${call};` : `\treturn ${call};`,
		"}",
	];
}

function guardedImportJs(name: string, params: string[], call: string): string {
	return `\t${name}: (${params.join(", ")}) => { try { return ${call}; } catch (e) { throw ${REGISTRY}.die(e); } },`;
}

export function wasmEntrySource(fns: BoundaryFunction[], importPathOf: (modulePath: string) => string): WasmEntry {
	const lines: string[] = [];
	const modules: string[] = [];
	for (const f of fns) {
		if (!modules.includes(f.modulePath)) modules.push(f.modulePath);
	}
	const aliasOf = (f: BoundaryFunction): string => `msbm${modules.indexOf(f.modulePath)}_${f.name}`;
	for (let m = 0; m < modules.length; m += 1) {
		let names = "";
		const imported: string[] = [];
		for (const f of fns) {
			if (f.modulePath != modules[m] || imported.includes(f.name)) continue;
			imported.push(f.name);
			if (names != "") names += ", ";
			names += `${f.name} as ${aliasOf(f)}`;
		}
		lines.push(`import { ${names} } from "${importPathOf(modules[m])}";`);
	}

	let hasStringParam = false;
	let hasStringResult = false;
	let hasStructString = false;
	let readsHeap = false;
	let copiesIn = false;
	let hasVecResult = false;
	let hasScalarSome = false;
	const vecElements: BoundaryKind[] = [];
	const resultImports: string[] = [];
	const addResultImport = (name: string): void => {
		if (!resultImports.includes(name)) resultImports.push(name);
	};
	for (const f of fns) {
		if (f.result == BoundaryKind.String) {
			hasStringResult = true;
			addResultImport("msb_rs_s");
		} else if (f.resultNullable && f.result != BoundaryKind.Struct && f.result != BoundaryKind.Vec) {
			hasScalarSome = true;
		}
		if (f.result == BoundaryKind.Vec) {
			readsHeap = true;
			hasVecResult = true;
		}
		if (f.result == BoundaryKind.Struct) {
			if (leafLetters(f.resultLeaves).includes("s")) hasStructString = true;
			addResultImport("msb_rs_" + leafLetters(f.resultLeaves));
		}
		for (const p of f.params) {
			if (p.kind == BoundaryKind.String) {
				hasStringParam = true;
				copiesIn = true;
			}
			if (p.kind == BoundaryKind.Callback && p.callback!.params.includes(BoundaryKind.String)) hasStringParam = true;
			if (p.kind == BoundaryKind.Callback && p.callback!.params.includes(BoundaryKind.Span)) readsHeap = true;
			if (p.kind == BoundaryKind.Struct && leafLetters(p.leaves).includes("s")) {
				hasStringParam = true;
				copiesIn = true;
			}
			if (p.kind == BoundaryKind.Vec || p.kind == BoundaryKind.Span) {
				readsHeap = true;
				copiesIn = true;
			}
			if (p.kind == BoundaryKind.Vec && !vecElements.includes(p.element)) vecElements.push(p.element);
		}
	}
	if (hasVecResult) resultImports.push("msb_rv");
	const hasString = hasStringParam || hasStringResult || hasStructString;
	if (hasString) for (const l of stringHelperLines()) lines.push(l);
	if (hasScalarSome) {
		lines.push("let msbRetSome: int32 = 0;");
		lines.push('@exportName("msb_ret_some")');
		lines.push("export function msb_ret_some(): int32 { return msbRetSome; }");
	}
	for (const k of vecElements) for (const l of vecFromLines(k)) lines.push(l);

	const signatures: string[] = [];
	for (const f of fns) {
		for (const p of f.params) {
			if (p.kind != BoundaryKind.Callback || signatures.includes(p.callback!.signature)) continue;
			signatures.push(p.callback!.signature);
			for (const l of callbackLines(p.callback!)) lines.push(l);
		}
	}
	for (const name of resultImports) {
		const letters = name == "msb_rv" ? "ii" : name.slice("msb_rs_".length);
		for (const l of importLines(name, letters, "v", false)) lines.push(l);
	}
	for (const f of fns) {
		for (const l of wrapperLines(f, aliasOf(f))) lines.push(l);
	}

	const exported: string[] = [];
	for (const f of fns) exported.push("_" + f.exportSymbol);
	if (hasScalarSome) exported.push("_msb_ret_some");
	if (copiesIn) {
		exported.push("_malloc");
		exported.push("_free");
	}
	exported.push("_MsMain");

	let jsLibrary = "";
	if (signatures.length > 0 || resultImports.length > 0) {
		const entries: string[] = [];
		for (const s of signatures) entries.push(callbackImportJs(s));
		for (const name of resultImports) entries.push(guardedImportJs(name, ["...a"], `${REGISTRY}.takes.pop()(...a)`));
		const first = signatures.length > 0 ? "msb_cb_" + signatures[0] : resultImports[0];
		entries.push(`\t${first}__postset: "if (!${REGISTRY}) throw new Error('msb registry missing: pass { msb } to the wasm module factory');",`);
		jsLibrary = "addToLibrary({\n" + entries.join("\n") + "\n});\n";
	}
	const runtimeMethods = hasString || readsHeap ? ["HEAPU8"] : [];
	return { source: lines.join("\n") + "\n", exportedFunctions: exported, jsLibrary, runtimeMethods };
}
