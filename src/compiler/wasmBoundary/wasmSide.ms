import {
	BoundaryKind,
	msTypeOf,
	signatureLetter,
	unwiredKind,
} from "./boundaryKinds";
import {
	BoundaryCallback,
	BoundaryFunction,
	BoundaryLeaf,
	BoundaryMode,
	BoundaryParam,
	leafLiteral,
} from "./manifest";

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

interface WireTypes {
	msType: string;
	cType: string;
}

function wireTypes(letter: string): WireTypes {
	return match (letter) {
		"i" => ({ msType: "int32", cType: "int32_t" }),
		"j" => ({ msType: "int64", cType: "int64_t" }),
		"f" => ({ msType: "float32", cType: "float" }),
		"d" => ({ msType: "float64", cType: "double" }),
		"v" => ({ msType: "void", cType: "void" }),
		_ => {
			throw new Error("internal: unknown callback signature letter " + letter);
		},
	};
}

function msValueToWire(kind: BoundaryKind, expr: string): string {
	return match (kind) {
		BoundaryKind.Bool => `(${expr} ? 1 : 0)`,
		BoundaryKind.U32 => `msbWireU32(${expr})`,
		BoundaryKind.U64 => `msbWireU64(${expr})`,
		_ => {
			const own = valueTypeOf(kind);
			const wire = wireTypes(signatureLetter(kind)).msType;
			own == wire ? expr : `(${expr} as ${wire})`
		},
	};
}

function wireToMsValue(kind: BoundaryKind, expr: string): string {
	return match (kind) {
		BoundaryKind.Bool => `(${expr} != 0)`,
		BoundaryKind.U32 => `msbUnwireU32(${expr})`,
		BoundaryKind.U64 => `msbUnwireU64(${expr})`,
		_ => {
			const own = valueTypeOf(kind);
			const wire = wireTypes(signatureLetter(kind)).msType;
			own == wire ? expr : `(${expr} as ${own})`
		},
	};
}

function wireNames(i: int32, letter: string): string[] {
	if (letter == "s" || letter == "p") return [`a${i}p`, `a${i}l`];
	return [`a${i}`];
}

function importLines(
	name: string,
	letters: string,
	result: string,
	withId: boolean,
): string[] {
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
		cParams.push(`${wireTypes(l).cType} ${names[0]}`);
		msParams.push(`${names[0]}: ${wireTypes(l).msType}`);
	}
	const attr = '__attribute__((import_module(\\"env\\"), '
		+ `import_name(\\"${name}\\")))`;
	const cParamList = cParams.length == 0 ? "void" : cParams.join(", ");
	const cResult = wireTypes(result).cType;
	const msResult = wireTypes(result).msType;
	return [
		`@emit("${attr} ${cResult} ${name}(${cParamList});");`,
		`extern function ${name}(${msParams.join(", ")}): ${msResult} `
			+ `from "${name}";`,
	];
}

function callbackLines(cb: BoundaryCallback): string[] {
	if (cb.result == BoundaryKind.String || cb.result == BoundaryKind.Span) {
		unwiredKind(cb.result, "callback result letter");
	}
	const name = "msb_cb_" + cb.signature;
	const letters = cb.signature.slice(2);
	return importLines(name, letters, cb.signature.slice(0, 1), true);
}

function callbackImportJs(signature: string): string {
	const letters = signature.slice(2);
	const wire: string[] = [];
	for (let i = 0; i < letters.length; i += 1) {
		for (const n of wireNames(i, letters.slice(i, i + 1))) wire.push(n);
	}
	const call = `${REGISTRY}.cb(id)(${wire.join(", ")})`;
	return guardedImportJs(`msb_cb_${signature}`, ["id", ...wire], call);
}

function leafLetters(leaves: BoundaryLeaf[]): string {
	let letters = "";
	for (const leaf of leaves) {
		letters += (leaf.nullable ? "i" : "") + signatureLetter(leaf.kind);
	}
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
			sig += `a${i}: string${nullable ? " | null" : ""}`;
			args += ", " + wireArgsOut(BoundaryKind.String, nullable, `a${i}`);
			continue;
		}
		if (params[i] == BoundaryKind.Span) {
			const t = valueTypeOf(cb.elements[i]);
			const shared = cb.modes[i] == BoundaryMode.Shared;
			const ptr = shared ? `Ptr<${t}>` : `Readonly<Ptr<${t}>>`;
			sig += `a${i}: ${shared ? `Span<${t}>` : `Readonly<Span<${t}>>`}`;
			const base = `a${i} as ${ptr} as uint64 as uint32`;
			args += `, (a${i}.length == 0 ? 0 : ${base}), a${i}.length as int32`;
			continue;
		}
		sig += `a${i}: ${valueTypeOf(params[i])}${nullable ? " | null" : ""}`;
		args += ", " + wireArgsOut(params[i], nullable, `a${i}`);
	}
	const call = `msb_cb_${cb.signature}(${args})`;
	if (cb.result == BoundaryKind.Void) return `(${sig}): void => { ${call}; }`;
	const result = msTypeOf(cb.result);
	return `(${sig}): ${result} => ${wireToMsValue(cb.result, call)}`;
}

function wireArgsOut(
	kind: BoundaryKind,
	nullable: boolean,
	value: string,
): string {
	const some = `(${value} != null ? 1 : 0)`;
	if (kind == BoundaryKind.String) {
		if (!nullable) return `msbStrPtr(${value}), ${value}.asBytes().length`;
		const ptr = `(${value} != null ? msbStrPtr(${value}) : 0)`;
		const len = `(${value} != null ? ${value}.asBytes().length : 0)`;
		return `${some}, ${ptr}, ${len}`;
	}
	if (!nullable) return msValueToWire(kind, value);
	return `${some}, ` + msValueToWire(kind, `(${value} ?? ${zeroOf(kind)})`);
}

function wireArgsIn(
	sigs: string[],
	name: string,
	kind: BoundaryKind,
	nullable: boolean,
): string {
	const some = `${name}Some`;
	if (nullable) sigs.push(`${some}: int32`);
	let value = name;
	if (kind == BoundaryKind.String) {
		sigs.push(`${name}Ptr: uint32, ${name}Len: int32`);
		value = `msbStrAdopt(${name}Ptr, ${name}Len)`;
	} else {
		sigs.push(`${name}: ${valueTypeOf(kind)}`);
	}
	return nullable ? orMaybe(some, value) : value;
}

function stringHelperLines(): string[] {
	return [
		"extern function msStringNew(data: cstring, length: int64): string;",
		"extern function msStringAdoptMalloced("
			+ "block: uint64, length: int64): string;",
		"function msbStrFrom(ptr: uint32, len: int32): string {",
		"\treturn msStringNew("
			+ "ptr as uint64 as Ptr<uint8> as cstring, len as int64);",
		"}",
		"function msbStrAdopt(ptr: uint32, len: int32): string {",
		"\treturn msStringAdoptMalloced(ptr as uint64, len as int64);",
		"}",
		"function msbStrPtr(s: string): uint32 {",
		"\treturn (s as cstring) as Ptr<uint8> as uint64 as uint32;",
		"}",
	];
}

function takenResult(
	f: BoundaryFunction,
	call: string,
	sig: string,
	take: string,
): string[] {
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
		const present = (value: string): string => {
			return p.nullable ? orMaybe(some, value) : value;
		};
		match (p.kind) {
			BoundaryKind.Callback => {
				sigs.push(`${p.name}: int32`);
				argList.push(closureOf(p.callback!, p.name));
			}
			BoundaryKind.Struct => {
				if (p.nullable) sigs.push(`${some}: int32`);
				const values: string[] = [];
				for (let j = 0; j < p.leaves.length; j += 1) {
					const leaf = p.leaves[j];
					const name = `${p.name}_${j}`;
					values.push(wireArgsIn(sigs, name, leaf.kind, leaf.nullable));
				}
				argList.push(present(leafLiteral(p.leaves, values, 0)));
			}
			BoundaryKind.Vec => {
				if (p.nullable) sigs.push(`${some}: int32`);
				sigs.push(`${p.name}Ptr: uint32, ${p.name}Len: int32`);
				const from = `msbVecFrom_${valueTypeOf(p.element)}`;
				argList.push(present(`${from}(${p.name}Ptr, ${p.name}Len)`));
			}
			BoundaryKind.Span => {
				sigs.push(`${p.name}Ptr: uint32, ${p.name}Len: int32`);
				const element = valueTypeOf(p.element);
				const view = `(${p.name}Ptr as uint64 as Ptr<${element}>)`;
				argList.push(`${view}[0..${p.name}Len]`);
			}
			_ => {
				argList.push(wireArgsIn(sigs, p.name, p.kind, p.nullable));
			}
		}
	}
	const sig = sigs.join(", ");
	const call = `${alias}(${argList.join(", ")})`;
	return match (f.result) {
		BoundaryKind.Struct => {
			const wires: string[] = [];
			for (const leaf of f.resultLeaves) {
				const value = `r.${leaf.path.join(".")}`;
				wires.push(wireArgsOut(leaf.kind, leaf.nullable, value));
			}
			const letters = leafLetters(f.resultLeaves);
			takenResult(f, call, sig, `msb_rs_${letters}(${wires.join(", ")});`)
		},
		BoundaryKind.Vec => {
			const t = valueTypeOf(f.resultElement);
			const base = `(r as Span<${t}>) as Ptr<void> as uint64 as int32`;
			takenResult(f, call, sig, `msb_rv(${base}, r.length as int32);`)
		},
		BoundaryKind.String => {
			if (f.resultNullable) {
				takenResult(f, call, sig, "msb_rs_s(msbStrPtr(r), r.asBytes().length);")
			} else {
				[
					`@exportName("${f.exportSymbol}")`,
					`export function ${f.exportSymbol}(${sig}): void {`,
					`\tconst r = ${call};`,
					"\tmsb_rs_s(msbStrPtr(r), r.asBytes().length);",
					"}",
				]
			}
		},
		_ => {
			if (f.resultNullable) {
				[
					`@exportName("${f.exportSymbol}")`,
					`export function ${f.exportSymbol}(${sig}): ${msTypeOf(f.result)} {`,
					`\tconst r = ${call};`,
					"\tmsbRetSome = r != null ? 1 : 0;",
					`\treturn r ?? ${zeroOf(f.result)};`,
					"}",
				]
			} else {
				[
					`@exportName("${f.exportSymbol}")`,
					`export function ${f.exportSymbol}(${sig}): ${msTypeOf(f.result)} {`,
					f.result == BoundaryKind.Void ? `\t${call};` : `\treturn ${call};`,
					"}",
				]
			}
		},
	};
}

function guardedImportJs(name: string, params: string[], call: string): string {
	const die = `catch (e) { throw ${REGISTRY}.die(e); }`;
	const list = params.join(", ");
	return `\t${name}: (${list}) => { try { return ${call}; } ${die} },`;
}

function unsignedWireLines(): string[] {
	return [
		"function msbWireU32(x: uint32): int32 { "
			+ "return x > 2147483647 ? -((~x) as int32) - 1 : x as int32; }",
		"function msbUnwireU32(w: int32): uint32 { "
			+ "return w < 0 ? ~((-(w + 1)) as uint32) : w as uint32; }",
		"function msbWireU64(x: uint64): int64 { "
			+ "return x > 9223372036854775807 ? -((~x) as int64) - 1 : x as int64; }",
		"function msbUnwireU64(w: int64): uint64 { "
			+ "return w < 0 ? ~((-(w + 1)) as uint64) : w as uint64; }",
	];
}

interface EntryUsage {
	modules: string[];
	hasString: boolean;
	readsHeap: boolean;
	copiesIn: boolean;
	hasScalarSome: boolean;
	vecElements: BoundaryKind[];
	resultImports: string[];
	callbacks: BoundaryCallback[];
}

function usageOf(fns: BoundaryFunction[]): EntryUsage {
	const usage: EntryUsage = {
		modules: [],
		hasString: false,
		readsHeap: false,
		copiesIn: false,
		hasScalarSome: false,
		vecElements: [],
		resultImports: [],
		callbacks: [],
	};
	let hasVecResult = false;
	const addResultImport = (name: string): void => {
		if (!usage.resultImports.includes(name)) usage.resultImports.push(name);
	};
	for (const f of fns) {
		if (!usage.modules.includes(f.modulePath)) {
			usage.modules.push(f.modulePath);
		}
		if (f.result == BoundaryKind.String) {
			usage.hasString = true;
			addResultImport("msb_rs_s");
		} else if (
			f.resultNullable
			&& f.result != BoundaryKind.Struct
			&& f.result != BoundaryKind.Vec
		) {
			usage.hasScalarSome = true;
		}
		if (f.result == BoundaryKind.Vec) {
			usage.readsHeap = true;
			hasVecResult = true;
		}
		if (f.result == BoundaryKind.Struct) {
			const letters = leafLetters(f.resultLeaves);
			if (letters.includes("s")) usage.hasString = true;
			addResultImport("msb_rs_" + letters);
		}
		for (const p of f.params) {
			if (p.kind == BoundaryKind.String) {
				usage.hasString = true;
				usage.copiesIn = true;
			}
			if (p.kind == BoundaryKind.Callback) {
				const cb = p.callback!;
				if (cb.params.includes(BoundaryKind.String)) {
					usage.hasString = true;
				}
				if (cb.params.includes(BoundaryKind.Span)) {
					usage.readsHeap = true;
				}
				if (!usage.callbacks.some((c) => c.signature == cb.signature)) {
					usage.callbacks.push(cb);
				}
			}
			if (
				p.kind == BoundaryKind.Struct
				&& leafLetters(p.leaves).includes("s")
			) {
				usage.hasString = true;
				usage.copiesIn = true;
			}
			if (p.kind == BoundaryKind.Vec || p.kind == BoundaryKind.Span) {
				usage.readsHeap = true;
				usage.copiesIn = true;
			}
			if (
				p.kind == BoundaryKind.Vec
				&& !usage.vecElements.includes(p.element)
			) {
				usage.vecElements.push(p.element);
			}
		}
	}
	if (hasVecResult) usage.resultImports.push("msb_rv");
	return usage;
}

function aliasOf(f: BoundaryFunction, modules: string[]): string {
	return `msbm${modules.indexOf(f.modulePath)}_${f.name}`;
}

function moduleImportLines(
	fns: BoundaryFunction[],
	modules: string[],
	importPathOf: (modulePath: string) => string,
): string[] {
	const lines: string[] = [];
	for (const modulePath of modules) {
		const names: string[] = [];
		const imported: string[] = [];
		for (const f of fns) {
			if (f.modulePath != modulePath || imported.includes(f.name)) continue;
			imported.push(f.name);
			names.push(`${f.name} as ${aliasOf(f, modules)}`);
		}
		const from = importPathOf(modulePath);
		lines.push(`import { ${names.join(", ")} } from "${from}";`);
	}
	return lines;
}

function jsLibraryOf(usage: EntryUsage): string {
	const signatures = usage.callbacks.map((cb) => cb.signature);
	if (signatures.length == 0 && usage.resultImports.length == 0) return "";
	const entries: string[] = [];
	for (const s of signatures) entries.push(callbackImportJs(s));
	for (const name of usage.resultImports) {
		const take = `${REGISTRY}.takes.pop()(...a)`;
		entries.push(guardedImportJs(name, ["...a"], take));
	}
	const first = signatures.length > 0
		? "msb_cb_" + signatures[0]
		: usage.resultImports[0];
	const missing = `if (!${REGISTRY}) throw new Error('msb registry missing: `
		+ "pass { msb } to the wasm module factory');";
	entries.push(`\t${first}__postset: "${missing}",`);
	return "addToLibrary({\n" + entries.join("\n") + "\n});\n";
}

function entryLines(
	fns: BoundaryFunction[],
	usage: EntryUsage,
	importPathOf: (modulePath: string) => string,
): string[] {
	const lines = moduleImportLines(fns, usage.modules, importPathOf);
	for (const l of unsignedWireLines()) lines.push(l);
	if (usage.hasString) for (const l of stringHelperLines()) lines.push(l);
	if (usage.hasScalarSome) {
		lines.push("let msbRetSome: int32 = 0;");
		lines.push('@exportName("msb_ret_some")');
		lines.push("export function msb_ret_some(): int32 { return msbRetSome; }");
	}
	for (const k of usage.vecElements) {
		for (const l of vecFromLines(k)) lines.push(l);
	}
	for (const cb of usage.callbacks) {
		for (const l of callbackLines(cb)) lines.push(l);
	}
	for (const name of usage.resultImports) {
		const letters = name == "msb_rv" ? "ii" : name.slice("msb_rs_".length);
		for (const l of importLines(name, letters, "v", false)) lines.push(l);
	}
	for (const f of fns) {
		for (const l of wrapperLines(f, aliasOf(f, usage.modules))) lines.push(l);
	}
	return lines;
}

function exportedSymbolsOf(
	fns: BoundaryFunction[],
	usage: EntryUsage,
): string[] {
	const exported = fns.map((f) => "_" + f.exportSymbol);
	if (usage.hasScalarSome) exported.push("_msb_ret_some");
	if (usage.copiesIn) {
		exported.push("_malloc");
		exported.push("_free");
	}
	exported.push("_MsMain");
	return exported;
}

export function wasmEntrySource(
	fns: BoundaryFunction[],
	importPathOf: (modulePath: string) => string,
): WasmEntry {
	const usage = usageOf(fns);
	return {
		source: entryLines(fns, usage, importPathOf).join("\n") + "\n",
		exportedFunctions: exportedSymbolsOf(fns, usage),
		jsLibrary: jsLibraryOf(usage),
		runtimeMethods: usage.hasString || usage.readsHeap ? ["HEAPU8"] : [],
	};
}
