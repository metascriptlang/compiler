import { preludeFor, quoted, viewHelpers } from "./jsGlue";
import { BoundaryKind, msTypeOf, scalarFacts, unwiredKind } from "./boundaryKinds";
import { BoundaryCallback, BoundaryFunction, BoundaryMode, BoundaryParam, Manifest, copiesArgsIn, leafLiteral } from "./manifest";

export interface JsModuleBindings {
	modulePath: string;
	code: string;
}

export interface JsBindings {
	prelude: string;
	modules: JsModuleBindings[];
}

export interface JsBindingOptions {
	checked: boolean;
}

function wireToJsValue(kind: BoundaryKind, expr: string): string {
	return match (kind) {
		BoundaryKind.Bool => `${expr} !== 0`,
		BoundaryKind.I8 => `(${expr} << 24) >> 24`,
		BoundaryKind.I16 => `(${expr} << 16) >> 16`,
		BoundaryKind.U8 => `${expr} & 255`,
		BoundaryKind.U16 => `${expr} & 65535`,
		BoundaryKind.U32 => `${expr} >>> 0`,
		BoundaryKind.U64 => `BigInt.asUintN(64, ${expr})`,
		BoundaryKind.I32 | BoundaryKind.I64 | BoundaryKind.F32 | BoundaryKind.F64 => expr,
		BoundaryKind.Void
			| BoundaryKind.Callback
			| BoundaryKind.String
			| BoundaryKind.Struct
			| BoundaryKind.Vec
			| BoundaryKind.Span => { unwiredKind(kind, "scalar conversion from the wasm side"); },
	};
}

function jsValueToWire(kind: BoundaryKind, expr: string): string {
	return match (kind) {
		BoundaryKind.Bool => `(${expr} ? 1 : 0)`,
		BoundaryKind.I8
			| BoundaryKind.I16
			| BoundaryKind.I32
			| BoundaryKind.U8
			| BoundaryKind.U16
			| BoundaryKind.U32
			| BoundaryKind.I64
			| BoundaryKind.U64
			| BoundaryKind.F32
			| BoundaryKind.F64 => expr,
		BoundaryKind.Void
			| BoundaryKind.Callback
			| BoundaryKind.String
			| BoundaryKind.Struct
			| BoundaryKind.Vec
			| BoundaryKind.Span => { unwiredKind(kind, "scalar conversion to the wasm side"); },
	};
}

function elementArgs(kind: BoundaryKind): string {
	const facts = scalarFacts(kind, "value range");
	const range = facts.range == null
		? "null, null"
		: `${facts.range.low}, ${facts.range.high}`;
	return `${quoted(facts.jsType)}, ${range}, ${quoted(facts.msType)}`;
}

function valueCheck(kind: BoundaryKind, expr: string, at: string): string {
	const facts = scalarFacts(kind, "JS type check");
	const jsType = quoted(facts.jsType);
	const msType = quoted(facts.msType);
	if (facts.range == null) {
		return `__msbType(${expr}, ${jsType}, ${msType}, ${at})`;
	}
	if (facts.jsType == "bigint") {
		const signed = kind == BoundaryKind.I64;
		return `__msbWide(${expr}, ${signed}, ${msType}, ${at})`;
	}
	const { low, high } = facts.range;
	return `__msbInt(${expr}, ${jsType}, ${low}, ${high}, ${msType}, ${at})`;
}

function typedArrayOf(kind: BoundaryKind): string {
	return scalarFacts(kind, "typed array").typedArray;
}

function objectCheck(expr: string, at: string): string {
	return `__msbType(${expr}, "object", "object", ${at});`;
}

function paramChecks(f: BoundaryFunction): string[] {
	const out: string[] = [];
	for (let i = 0; i < f.params.length; i += 1) {
		const p: BoundaryParam = f.params[i];
		const label = `parameter '${p.name}'`;
		const at = (what: string): string => `${quoted(f.name)}, ${quoted(what)}`;
		const x = `a${i}`;
		const mark = out.length;
		match (p.kind) {
			BoundaryKind.String => {
				out.push(`__msbType(${x}, "string", "string", ${at(label)});`);
			}
			BoundaryKind.Callback => {
				out.push(`__msbType(${x}, "function", "function", ${at(label)});`);
			}
			BoundaryKind.Struct => {
				out.push(objectCheck(x, at(label)));
				const seen: string[] = [];
				for (const leaf of p.leaves) {
					for (let d = 1; d < leaf.path.length; d += 1) {
						const prefix = leaf.path.slice(0, d).join(".");
						if (seen.includes(prefix)) continue;
						seen.push(prefix);
						out.push(objectCheck(`${x}.${prefix}`, at(`${label} field '${prefix}'`)));
					}
					const path = leaf.path.join(".");
					const where = at(`${label} field '${path}'`);
					const skip = leaf.nullable ? `if (${x}.${path} != null) ` : "";
					if (leaf.kind == BoundaryKind.String) out.push(`${skip}__msbType(${x}.${path}, "string", "string", ${where});`);
					else out.push(skip + valueCheck(leaf.kind, `${x}.${path}`, where) + ";");
				}
			}
			BoundaryKind.Vec => {
				out.push(`__msbElems(__msbList(${x}, ${quoted(`Vec<${msTypeOf(p.element)}>`)}, ${at(label)}), 0, ${x}.length, ${elementArgs(p.element)}, ${at(label)});`);
			}
			BoundaryKind.Span => {
				out.push(`__msbElems(__msbSpan(${x}, ${quoted(`Span<${msTypeOf(p.element)}>`)}, ${at(label)}).base, ${x}.off, ${x}.len, ${elementArgs(p.element)}, ${at(label)});`);
			}
			_ => {
				out.push(valueCheck(p.kind, x, at(label)) + ";");
			}
		}
		if (p.nullable) {
			for (let k = mark; k < out.length; k += 1) out[k] = `if (${x} != null) ${out[k]}`;
		}
	}
	return out;
}

function guarded(flag: string, expr: string): string {
	return flag == "" ? expr : `${flag} !== 0 ? ${expr} : null`;
}

function anyOf(a: string, b: string): string {
	return a == "" ? b : b == "" ? a : `${a} || ${b}`;
}

function callbackSharesViews(cb: BoundaryCallback): boolean {
	let spans = 0;
	let written = false;
	for (let i = 0; i < cb.params.length; i += 1) {
		if (cb.params[i] != BoundaryKind.Span) continue;
		spans += 1;
		if (cb.modes[i] == BoundaryMode.Shared) written = true;
	}
	return spans >= 2 && written;
}

function adapterOf(cb: BoundaryCallback, target: string, resultAt: string | null): string {
	let names = "";
	let args = "";
	let views = "";
	let writesBack = "";
	const shared = callbackSharesViews(cb);
	const ranges: string[] = [];
	let w = 0;
	for (let i = 0; i < cb.params.length; i += 1) {
		if (i > 0) args += ", ";
		if (w > 0) names += ", ";
		let flag = "";
		if (cb.nullables[i]) {
			flag = `x${w}`;
			names += `${flag}, `;
			w += 1;
		}
		if (cb.params[i] == BoundaryKind.String) {
			names += `x${w}, x${w + 1}`;
			args += guarded(flag, `__msbDec(x${w}, x${w + 1})`);
			w += 2;
		} else if (cb.params[i] == BoundaryKind.Span) {
			const t = typedArrayOf(cb.elements[i]);
			const bool = cb.elements[i] == BoundaryKind.Bool;
			const written = cb.modes[i] == BoundaryMode.Shared;
			names += `x${w}, x${w + 1}`;
			if (shared) {
				const v = `vs[${ranges.length}]`;
				ranges.push(`[x${w} >>> 0, x${w + 1}, ${t}, ${bool}]`);
				if (written) writesBack += `__msbCopyTo(x${w} >>> 0, ${v}.base, ${v}.off, x${w + 1}, ${t}); `;
				args += v;
			} else {
				views += `const s${i} = { base: __msbVecOut(x${w} >>> 0, x${w + 1}, ${t}, ${bool}), off: 0, len: x${w + 1} }; `;
				if (written) writesBack += `__msbCopyTo(x${w} >>> 0, s${i}.base, 0, x${w + 1}, ${t}); `;
				args += `s${i}`;
			}
			w += 2;
		} else {
			names += `x${w}`;
			args += guarded(flag, wireToJsValue(cb.params[i], `x${w}`));
			w += 1;
		}
	}
	if (shared) views = `const vs = __msbVecViews([${ranges.join(", ")}]); `;
	let call = `${target}(${args})`;
	if (resultAt != null && cb.result != BoundaryKind.Void) call = valueCheck(cb.result, call, resultAt);
	const body =cb.result == BoundaryKind.Void ? `${call};` : `return ${jsValueToWire(cb.result, call)};`;
	if (writesBack != "") return `(${names}) => { ${views}try { ${body} } finally { ${writesBack}} }`;
	if (views != "") return `(${names}) => { ${views}${body} }`;
	if (cb.result == BoundaryKind.Void) return `(${names}) => { ${call}; }`;
	return `(${names}) => ${jsValueToWire(cb.result, call)}`;
}

function forwardsUnchanged(cb: BoundaryCallback, adapter: string, target: string): boolean {
	const names: string[] = [];
	for (let i = 0; i < cb.params.length; i += 1) names.push(`x${i}`);
	const list = names.join(", ");
	const call = `${target}(${list})`;
	return adapter == `(${list}) => ${call}` || adapter == `(${list}) => { ${call}; }`;
}

function takerOf(f: BoundaryFunction): string {
	if (f.result == BoundaryKind.String) {
		return "(p, n) => { r = __msbDec(p >>> 0, n); }";
	}
	if (f.result == BoundaryKind.Vec) {
		return `(p, n) => { r = __msbVecOut(p >>> 0, n, ${typedArrayOf(f.resultElement)}, ${f.resultElement == BoundaryKind.Bool}); }`;
	}
	const names: string[] = [];
	const values: string[] = [];
	let w = 0;
	for (const leaf of f.resultLeaves) {
		let flag = "";
		if (leaf.nullable) {
			flag = `x${w}`;
			names.push(flag);
			w += 1;
		}
		if (leaf.kind == BoundaryKind.String) {
			names.push(`x${w}, x${w + 1}`);
			values.push(guarded(flag, `__msbDec(x${w}, x${w + 1})`));
			w += 2;
		} else {
			names.push(`x${w}`);
			values.push(guarded(flag, wireToJsValue(leaf.kind, `x${w}`)));
			w += 1;
		}
	}
	return `(${names.join(", ")}) => { r = ${leafLiteral(f.resultLeaves, values, 0)}; }`;
}

function afterCall(body: string[], afters: string[]): string[] {
	const n = afters.length;
	const out: string[] = [];
	for (let k = 0; k < n; k += 1) out.push("\t".repeat(k) + "try {");
	for (const l of body) out.push("\t".repeat(n) + l);
	for (let k = n - 1; k >= 0; k -= 1) {
		out.push("\t".repeat(k) + "} finally {");
		out.push("\t".repeat(k + 1) + afters[k]);
		out.push("\t".repeat(k) + "}");
	}
	return out;
}

function functionSharesViews(f: BoundaryFunction): boolean {
	let views = 0;
	let written = false;
	for (const p of f.params) {
		if (p.kind == BoundaryKind.Vec || p.kind == BoundaryKind.Span) views += 1;
		if (p.kind == BoundaryKind.Span && p.mode == BoundaryMode.Shared) written = true;
	}
	return views >= 2 && written;
}

function wrapperLines(f: BoundaryFunction, bundleName: string, options: JsBindingOptions): string[] {
	const cleanup: string[] = [];
	const copyBacks: string[] = [];
	const lines: string[] = [];
	const encoded: string[] = [];
	const encodes: string[] = [];
	const sigs: string[] = [];
	const argList: string[] = [];
	let wasmOwns = false;
	const shared = functionSharesViews(f);
	const sharedNames: string[] = [];
	const sharedViews: string[] = [];
	const encode = (name: string, expr: string, fn: string, adopted: boolean, absent: string): void => {
		if (adopted) wasmOwns = true;
		encoded.push(name);
		cleanup.push(adopted ? `if (${name} && !sent) __msbMod._free(${name}[0]);` : `if (${name}) __msbFree(${name}[0]);`);
		if (absent == "") {
			encodes.push(`		${name} = ${fn}(${expr});`);
			argList.push(`${name}[0], ${name}[1]`);
		} else {
			encodes.push(`		${name} = ${absent} ? null : ${fn}(${expr});`);
			argList.push(`${name} ? ${name}[0] : 0, ${name} ? ${name}[1] : 0`);
		}
	};
	const encodeView = (name: string, view: string, absent: string, role: string, label: string): void => {
		if (!shared) {
			encode(name, view, "__msbCopyIn", false, absent);
			return;
		}
		encoded.push(name);
		sharedNames.push(name);
		const entry = `${view}, ${quoted(role)}, ${quoted(label)}`;
		if (absent == "") {
			sharedViews.push(`[${entry}]`);
			argList.push(`${name}[0], ${name}[1]`);
		} else {
			sharedViews.push(`${absent} ? null : [${entry}]`);
			argList.push(`${name} ? ${name}[0] : 0, ${name} ? ${name}[1] : 0`);
		}
	};
	for (let i = 0; i < f.params.length; i += 1) {
		const p: BoundaryParam = f.params[i];
		sigs.push(`a${i}`);
		const own = p.nullable ? `a${i} == null` : "";
		if (p.nullable) argList.push(`${own} ? 0 : 1`);
		match (p.kind) {
			BoundaryKind.String => {
				encode(`e${i}`, `a${i}`, "__msbEncOwned", true, own);
			}
			BoundaryKind.Callback => {
				let resultAt: string | null = null;
				if (options.checked) resultAt = `${quoted(f.name)}, ${quoted(`result of callback '${p.name}'`)}`;
				const target = `a${i}`;
				const adapter = adapterOf(p.callback!, target, resultAt);
				lines.push(`	const id${i} = __msb.push(${forwardsUnchanged(p.callback!, adapter, target) ? target : adapter});`);
				cleanup.push(`__msb.pop(id${i});`);
				argList.push(`id${i}`);
			}
			BoundaryKind.Struct => {
				for (let j = 0; j < p.leaves.length; j += 1) {
					const leaf = p.leaves[j];
					const expr = `a${i}.${leaf.path.join(".")}`;
					const absent = anyOf(own, leaf.nullable ? `${expr} == null` : "");
					if (leaf.nullable) argList.push(`${absent} ? 0 : 1`);
					if (leaf.kind == BoundaryKind.String) encode(`e${i}_${j}`, expr, "__msbEncOwned", true, absent);
					else if (absent == "") argList.push(jsValueToWire(leaf.kind, expr));
					else argList.push(`${absent} ? ${scalarFacts(leaf.kind, "zero").jsZero} : ${jsValueToWire(leaf.kind, expr)}`);
				}
			}
			BoundaryKind.Vec => {
				encodeView(`e${i}`, `a${i}, 0, a${i}.length, ${typedArrayOf(p.element)}`, own, "copy", `parameter '${p.name}'`);
			}
			BoundaryKind.Span => {
				const view = `a${i}.base, a${i}.off, a${i}.len, ${typedArrayOf(p.element)}`;
				if (p.mode == BoundaryMode.Shared) copyBacks.push(`__msbCopyBack(e${i}[0], ${view}, ${p.element == BoundaryKind.Bool});`);
				encodeView(`e${i}`, view, "", p.mode == BoundaryMode.Shared ? "write" : "read", `parameter '${p.name}'`);
			}
			_ => {
				if (p.nullable) {
					argList.push(`${own} ? ${scalarFacts(p.kind, "zero").jsZero} : ${jsValueToWire(p.kind, `a${i}`)}`);
				} else {
					argList.push(jsValueToWire(p.kind, `a${i}`));
				}
			}
		}
	}
	if (shared) {
		lines.push("	const hb = [];");
		encodes.push(`		[${sharedNames.join(", ")}] = __msbCopyInViews([${sharedViews.join(", ")}], hb, ${quoted(f.name)});`);
		cleanup.push("for (const q of hb) __msbFree(q);");
	}
	const sig = sigs.join(", ");
	const call = `__msbMod._${f.exportSymbol}(${argList.join(", ")})`;
	const body: string[] = match (f.result) {
		BoundaryKind.Void => [`${call};`],
		BoundaryKind.String | BoundaryKind.Struct | BoundaryKind.Vec => {
			lines.push(f.resultNullable ? "	let r = null;" : "	let r;");
			lines.push(`	const d = __msb.takes.push(${takerOf(f)}) - 1;`);
			cleanup.push("__msb.takes.length = d;");
			[`${call};`, "return r;"]
		},
		_ => {
			if (f.resultNullable) {
				[
					`const v = ${call};`,
					`return __msbMod._msb_ret_some() !== 0 ? ${wireToJsValue(f.result, "v")} : null;`,
				]
			} else {
				[`return ${wireToJsValue(f.result, call)};`]
			}
		},
	};
	const out = [`function ${bundleName}(${sig}) {`];
	if (options.checked) {
		for (const c of paramChecks(f)) out.push(`	${c}`);
	}
	out.push("	__msb.enter();");
	if (cleanup.length == 0) {
		for (const l of body) out.push(`	${l}`);
	} else {
		for (const l of lines) out.push(l);
		if (encoded.length > 0) {
			out.push(`	let ${encoded.join(", ")}${wasmOwns ? ", sent = false" : ""};`);
			out.push("	const mark = __msbTop;");
		}
		out.push("	try {");
		for (const l of encodes) out.push(l);
		if (wasmOwns) out.push("		sent = true;");
		for (const l of afterCall(body, copyBacks)) out.push(`		${l}`);
		out.push("	} finally {");
		if (encoded.length > 0) out.push("		__msbTop = mark;");
		for (const c of cleanup) out.push(`		${c}`);
		out.push("	}");
	}
	out.push("}");
	return out;
}

export function jsBindings(m: Manifest, wasmModuleUrl: string, bundleNameOf: (f: BoundaryFunction) => string, options: JsBindingOptions): JsBindings {
	const modules: JsModuleBindings[] = [];
	const lines: string[][] = [];
	let scratch = false;
	let viewsIn = false;
	let viewsOut = false;
	for (const f of m.functions) {
		if (copiesArgsIn(f)) scratch = true;
		if (functionSharesViews(f)) viewsIn = true;
		for (const p of f.params) {
			if (p.kind == BoundaryKind.Callback && callbackSharesViews(p.callback!)) viewsOut = true;
		}
		let at = -1;
		for (let i = 0; i < modules.length; i += 1) {
			if (modules[i].modulePath == f.modulePath) at = i;
		}
		if (at < 0) {
			modules.push({ modulePath: f.modulePath, code: "" });
			lines.push([]);
			at = modules.length - 1;
		}
		for (const l of wrapperLines(f, bundleNameOf(f), options)) lines[at].push(l);
	}
	for (let i = 0; i < modules.length; i += 1) modules[i].code = lines[i].join("\n") + "\n";
	const views = viewHelpers(viewsIn, viewsOut);
	return { prelude: preludeFor(wasmModuleUrl, options.checked, scratch, views), modules };
}
