import { BoundaryCallback, BoundaryFunction, BoundaryKind, BoundaryParam, signatureLetter } from "./manifest";

export interface WasmEntry {
	source: string;
	exportedFunctions: string[];
	jsLibrary: string;
	runtimeMethods: string[];
}

function msTypeOf(kind: BoundaryKind): string {
	switch (kind) {
		case BoundaryKind.Bool: return "boolean";
		case BoundaryKind.I8: return "int8";
		case BoundaryKind.I16: return "int16";
		case BoundaryKind.I32: return "int32";
		case BoundaryKind.I64: return "int64";
		case BoundaryKind.U8: return "uint8";
		case BoundaryKind.U16: return "uint16";
		case BoundaryKind.U32: return "uint32";
		case BoundaryKind.U64: return "uint64";
		case BoundaryKind.F32: return "float32";
		case BoundaryKind.F64: return "float64";
		case BoundaryKind.Void: return "void";
		default: throw new Error("internal: boundary kind " + kind.toString() + " has no scalar type");
	}
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
	if (kind == BoundaryKind.Bool) return `(${expr} ? 1 : 0)`;
	const letter = signatureLetter(kind);
	const wire = wireMsType(letter);
	return msTypeOf(kind) == wire ? expr : `(${expr} as ${wire})`;
}

function fromWire(kind: BoundaryKind, expr: string): string {
	if (kind == BoundaryKind.Bool) return `(${expr} != 0)`;
	const wire = wireMsType(signatureLetter(kind));
	return msTypeOf(kind) == wire ? expr : `(${expr} as ${msTypeOf(kind)})`;
}

function callbackLines(cb: BoundaryCallback): string[] {
	const letters = cb.signature.slice(2);
	const result = cb.signature.slice(0, 1);
	let cParams = "int32_t id";
	let msParams = "id: int32";
	for (let i = 0; i < letters.length; i += 1) {
		const l = letters.slice(i, i + 1);
		if (l == "s") {
			cParams += `, uint32_t a${i}p, int32_t a${i}l`;
			msParams += `, a${i}p: uint32, a${i}l: int32`;
			continue;
		}
		cParams += `, ${wireCType(l)} a${i}`;
		msParams += `, a${i}: ${wireMsType(l)}`;
	}
	const name = "msb_cb_" + cb.signature;
	const attr = `__attribute__((import_module(\\"env\\"), import_name(\\"${name}\\")))`;
	return [
		`@emit("${attr} ${wireCType(result)} ${name}(${cParams});");`,
		`extern function ${name}(${msParams}): ${wireMsType(result)} from "${name}";`,
	];
}

function closureOf(cb: BoundaryCallback, idName: string): string {
	const params = cb.params;
	let sig = "";
	let args = idName;
	for (let i = 0; i < params.length; i += 1) {
		if (i > 0) sig += ", ";
		if (params[i] == BoundaryKind.String) {
			sig += `a${i}: string`;
			args += `, msbStrPtr(a${i}), a${i}.asBytes().length`;
			continue;
		}
		sig += `a${i}: ${msTypeOf(params[i])}`;
		args += ", " + toWire(params[i], `a${i}`);
	}
	const call = `msb_cb_${cb.signature}(${args})`;
	if (cb.result == BoundaryKind.Void) return `(${sig}): void => { ${call}; }`;
	return `(${sig}): ${msTypeOf(cb.result)} => ${fromWire(cb.result, call)}`;
}

function stringHelperLines(withResult: boolean): string[] {
	const lines = [
		"extern function msStringNew(data: cstring, length: int64): string;",
		"function msbStrFrom(ptr: uint32, len: int32): string {",
		"\treturn msStringNew(ptr as uint64 as Ptr<uint8> as cstring, len as int64);",
		"}",
		"function msbStrPtr(s: string): uint32 {",
		"\treturn (s as cstring) as Ptr<uint8> as uint64 as uint32;",
		"}",
	];
	if (withResult) {
		lines.push('let msbRet: string = "";');
		lines.push('@exportName("msb_ret_len")');
		lines.push("export function msb_ret_len(): int32 { return msbRet.asBytes().length; }");
	}
	return lines;
}

function wrapperLines(f: BoundaryFunction, alias: string): string[] {
	let sig = "";
	let args = "";
	for (let i = 0; i < f.params.length; i += 1) {
		const p: BoundaryParam = f.params[i];
		if (i > 0) { sig += ", "; args += ", "; }
		if (p.kind == BoundaryKind.String) {
			sig += `${p.name}Ptr: uint32, ${p.name}Len: int32`;
			args += `msbStrFrom(${p.name}Ptr, ${p.name}Len)`;
		} else if (p.kind == BoundaryKind.Callback) {
			sig += `${p.name}: int32`;
			args += closureOf(p.callback!, p.name);
		} else {
			sig += `${p.name}: ${msTypeOf(p.kind)}`;
			args += p.name;
		}
	}
	const call = `${alias}(${args})`;
	if (f.result == BoundaryKind.String) {
		return [
			`@exportName("${f.exportSymbol}")`,
			`export function ${f.exportSymbol}(${sig}): uint32 {`,
			`\tmsbRet = ${call};`,
			"\treturn msbStrPtr(msbRet);",
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

export function wasmEntrySource(fns: BoundaryFunction[], importPathOf: (modulePath: string) => string): WasmEntry {
	const lines: string[] = [];
	const modules: string[] = [];
	for (const f of fns) {
		if (!modules.includes(f.modulePath)) modules.push(f.modulePath);
	}
	const aliasOf = (f: BoundaryFunction): string => `msbm${modules.indexOf(f.modulePath)}_${f.name}`;
	for (let m = 0; m < modules.length; m += 1) {
		let names = "";
		for (const f of fns) {
			if (f.modulePath != modules[m]) continue;
			if (names != "") names += ", ";
			names += `${f.name} as ${aliasOf(f)}`;
		}
		lines.push(`import { ${names} } from "${importPathOf(modules[m])}";`);
	}

	let hasStringParam = false;
	let hasStringResult = false;
	for (const f of fns) {
		if (f.result == BoundaryKind.String) hasStringResult = true;
		for (const p of f.params) {
			if (p.kind == BoundaryKind.String) hasStringParam = true;
			if (p.kind == BoundaryKind.Callback && p.callback!.params.includes(BoundaryKind.String)) hasStringParam = true;
		}
	}
	const hasString = hasStringParam || hasStringResult;
	if (hasString) for (const l of stringHelperLines(hasStringResult)) lines.push(l);

	const signatures: string[] = [];
	for (const f of fns) {
		for (const p of f.params) {
			if (p.kind != BoundaryKind.Callback || signatures.includes(p.callback!.signature)) continue;
			signatures.push(p.callback!.signature);
			for (const l of callbackLines(p.callback!)) lines.push(l);
		}
	}
	for (const f of fns) {
		for (const l of wrapperLines(f, aliasOf(f))) lines.push(l);
	}

	const exported: string[] = [];
	for (const f of fns) exported.push("_" + f.exportSymbol);
	if (hasStringResult) exported.push("_msb_ret_len");
	if (hasString) {
		exported.push("_malloc");
		exported.push("_free");
	}
	exported.push("_MsMain");

	let jsLibrary = "";
	if (signatures.length > 0) {
		const entries: string[] = [];
		for (const s of signatures) entries.push(`\tmsb_cb_${s}: (id, ...a) => globalThis.__msb.cb(id, ...a),`);
		jsLibrary = "addToLibrary({\n" + entries.join("\n") + "\n});\n";
	}
	const runtimeMethods = hasString ? ["HEAPU8", "wasmMemory"] : [];
	return { source: lines.join("\n") + "\n", exportedFunctions: exported, jsLibrary, runtimeMethods };
}
