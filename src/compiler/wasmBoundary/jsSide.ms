import { preludeFor, quoted, viewHelpers } from "./jsGlue";
import {
	BoundaryKind,
	msTypeOf,
	scalarFacts,
	unwiredKind,
} from "./boundaryKinds";
import {
	BoundaryCallback,
	BoundaryFunction,
	BoundaryMode,
	BoundaryParam,
	Manifest,
	copiesArgsIn,
	leafLiteral,
} from "./manifest";

export interface JsModuleBindings {
	modulePath: string;
	code: string;
}

export interface JsBindings {
	prelude: string;
	modules: JsModuleBindings[];
}

export interface JsBindingOptions {
	checked: (bundleName: string) => boolean;
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
		BoundaryKind.I32
			| BoundaryKind.I64
			| BoundaryKind.F32
			| BoundaryKind.F64 => expr,
		BoundaryKind.Void
			| BoundaryKind.Callback
			| BoundaryKind.String
			| BoundaryKind.Struct
			| BoundaryKind.Vec
			| BoundaryKind.Span
			| BoundaryKind.Handle => {
				unwiredKind(kind, "scalar conversion from the wasm side");
			},
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
			| BoundaryKind.Span
			| BoundaryKind.Handle => {
				unwiredKind(kind, "scalar conversion to the wasm side");
			},
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

function elementsCheck(
	source: string,
	range: string,
	element: BoundaryKind,
	at: string,
): string {
	return `__msbElems(${source}, ${range}, ${elementArgs(element)}, ${at});`;
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
						const where = at(`${label} field '${prefix}'`);
						out.push(objectCheck(`${x}.${prefix}`, where));
					}
					const path = leaf.path.join(".");
					const where = at(`${label} field '${path}'`);
					const skip = leaf.nullable ? `if (${x}.${path} != null) ` : "";
					if (leaf.kind == BoundaryKind.String) {
						const value = `${x}.${path}`;
						const check = `__msbType(${value}, "string", "string", ${where});`;
						out.push(skip + check);
					} else {
						out.push(skip + valueCheck(leaf.kind, `${x}.${path}`, where) + ";");
					}
				}
			}
			BoundaryKind.Vec => {
				const type = quoted(`Vec<${msTypeOf(p.element)}>`);
				const list = `__msbList(${x}, ${type}, ${at(label)})`;
				out.push(elementsCheck(list, `0, ${x}.length`, p.element, at(label)));
			}
			BoundaryKind.Span => {
				const type = quoted(`Span<${msTypeOf(p.element)}>`);
				const base = `__msbSpan(${x}, ${type}, ${at(label)}).base`;
				const range = `${x}.off, ${x}.len`;
				out.push(elementsCheck(base, range, p.element, at(label)));
			}
			_ => {
				out.push(valueCheck(p.kind, x, at(label)) + ";");
			}
		}
		if (p.nullable) {
			for (let k = mark; k < out.length; k += 1) {
				out[k] = `if (${x} != null) ${out[k]}`;
			}
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

function vecOut(ptr: string, len: string, element: BoundaryKind): string {
	const bool = element == BoundaryKind.Bool;
	return `__msbVecOut(${ptr}, ${len}, ${typedArrayOf(element)}, ${bool})`;
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

interface WireRead {
	names: string;
	value: string;
	width: int32;
}

function wireRead(kind: BoundaryKind, nullable: boolean, w: int32): WireRead {
	const flag = nullable ? `x${w}` : "";
	const at = nullable ? w + 1 : w;
	const prefix = nullable ? `${flag}, ` : "";
	if (kind == BoundaryKind.String) {
		return {
			names: `${prefix}x${at}, x${at + 1}`,
			value: guarded(flag, `__msbDec(x${at}, x${at + 1})`),
			width: at + 2 - w,
		};
	}
	return {
		names: `${prefix}x${at}`,
		value: guarded(flag, wireToJsValue(kind, `x${at}`)),
		width: at + 1 - w,
	};
}

function lentWhile(statements: string): string {
	return `__msb.lent += 1; try { ${statements} } finally { __msb.lent -= 1; }`;
}

function adapterOf(
	cb: BoundaryCallback,
	target: string,
	resultAt: string | null,
): string {
	const names: string[] = [];
	const args: string[] = [];
	let views = "";
	let writesBack = "";
	const shared = callbackSharesViews(cb);
	const ranges: string[] = [];
	let w = 0;
	for (let i = 0; i < cb.params.length; i += 1) {
		if (cb.params[i] != BoundaryKind.Span) {
			const read = wireRead(cb.params[i], cb.nullables[i], w);
			names.push(read.names);
			args.push(read.value);
			w += read.width;
			continue;
		}
		const at = cb.nullables[i] ? w + 1 : w;
		if (cb.nullables[i]) names.push(`x${w}, x${at}, x${at + 1}`);
		else names.push(`x${at}, x${at + 1}`);
		const t = typedArrayOf(cb.elements[i]);
		const bool = cb.elements[i] == BoundaryKind.Bool;
		const written = cb.modes[i] == BoundaryMode.Shared;
		const ptr = `x${at} >>> 0`;
		const len = `x${at + 1}`;
		if (shared) {
			const v = `vs[${ranges.length}]`;
			ranges.push(`[${ptr}, ${len}, ${t}, ${bool}]`);
			if (written) {
				const dest = `${v}.base, ${v}.off`;
				writesBack += `__msbCopyTo(${ptr}, ${dest}, ${len}, ${t}); `;
			}
			args.push(v);
		} else {
			const base = vecOut(ptr, len, cb.elements[i]);
			views += `const s${i} = { base: ${base}, off: 0, len: ${len} }; `;
			if (written) {
				writesBack += `__msbCopyTo(${ptr}, s${i}.base, 0, ${len}, ${t}); `;
			}
			args.push(`s${i}`);
		}
		w = at + 2;
	}
	if (shared) views = `const vs = __msbVecViews([${ranges.join(", ")}]); `;
	let call = `${target}(${args.join(", ")})`;
	const isVoid = cb.result == BoundaryKind.Void;
	if (resultAt != null && !isVoid) call = valueCheck(cb.result, call, resultAt);
	const returned = isVoid ? "" : jsValueToWire(cb.result, call);
	const body = isVoid ? `${call};` : `return ${returned};`;
	const params = names.join(", ");
	if (views != "") {
		const inner = writesBack != ""
			? `${views}try { ${body} } finally { ${writesBack}}`
			: `${views}${body}`;
		return `(${params}) => { ${lentWhile(inner)} }`;
	}
	if (isVoid) return `(${params}) => { ${call}; }`;
	return `(${params}) => ${returned}`;
}

function forwardsUnchanged(
	cb: BoundaryCallback,
	adapter: string,
	target: string,
): boolean {
	const names: string[] = [];
	for (let i = 0; i < cb.params.length; i += 1) names.push(`x${i}`);
	const list = names.join(", ");
	const call = `${target}(${list})`;
	return adapter == `(${list}) => ${call}`
		|| adapter == `(${list}) => { ${call}; }`;
}

function takerOf(f: BoundaryFunction): string {
	if (f.result == BoundaryKind.String) {
		return "(p, n) => { r = __msbDec(p >>> 0, n); }";
	}
	if (f.result == BoundaryKind.Vec) {
		return `(p, n) => { r = ${vecOut("p >>> 0", "n", f.resultElement)}; }`;
	}
	const names: string[] = [];
	const values: string[] = [];
	let w = 0;
	for (const leaf of f.resultLeaves) {
		const read = wireRead(leaf.kind, leaf.nullable, w);
		names.push(read.names);
		values.push(read.value);
		w += read.width;
	}
	const literal = leafLiteral(f.resultLeaves, values, 0);
	return `(${names.join(", ")}) => { r = ${literal}; }`;
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
		if (p.kind == BoundaryKind.Span && p.mode == BoundaryMode.Shared) {
			written = true;
		}
	}
	return views >= 2 && written;
}

function scalarArg(kind: BoundaryKind, expr: string, absent: string): string {
	const wire = jsValueToWire(kind, expr);
	if (absent == "") return wire;
	return `${absent} ? ${scalarFacts(kind, "zero").jsZero} : ${wire}`;
}

function wrapperLines(
	f: BoundaryFunction,
	bundleName: string,
	checked: boolean,
): string[] {
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
	const encode = (
		name: string,
		expr: string,
		fn: string,
		adopted: boolean,
		absent: string,
	): void => {
		if (adopted) wasmOwns = true;
		encoded.push(name);
		cleanup.push(
			adopted
				? `if (${name} && !sent) __msbMod._free(${name}[0]);`
				: `if (${name}) __msbFree(${name}[0]);`,
		);
		if (absent == "") {
			encodes.push(`		${name} = ${fn}(${expr});`);
			argList.push(`${name}[0], ${name}[1]`);
		} else {
			encodes.push(`		${name} = ${absent} ? null : ${fn}(${expr});`);
			argList.push(`${name} ? ${name}[0] : 0, ${name} ? ${name}[1] : 0`);
		}
	};
	const encodeView = (
		name: string,
		view: string,
		absent: string,
		role: string,
		label: string,
	): void => {
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
				if (checked) {
					const what = quoted(`result of callback '${p.name}'`);
					resultAt = `${quoted(f.name)}, ${what}`;
				}
				const target = `a${i}`;
				const adapter = adapterOf(p.callback!, target, resultAt);
				const pushed = forwardsUnchanged(p.callback!, adapter, target)
					? target
					: adapter;
				lines.push(`\tconst id${i} = __msb.push(${pushed});`);
				cleanup.push(`__msb.pop(id${i});`);
				argList.push(`id${i}`);
			}
			BoundaryKind.Struct => {
				for (let j = 0; j < p.leaves.length; j += 1) {
					const leaf = p.leaves[j];
					const expr = `a${i}.${leaf.path.join(".")}`;
					const absent = anyOf(own, leaf.nullable ? `${expr} == null` : "");
					if (leaf.nullable) argList.push(`${absent} ? 0 : 1`);
					if (leaf.kind == BoundaryKind.String) {
						encode(`e${i}_${j}`, expr, "__msbEncOwned", true, absent);
					} else {
						argList.push(scalarArg(leaf.kind, expr, absent));
					}
				}
			}
			BoundaryKind.Vec => {
				const view = `a${i}, 0, a${i}.length, ${typedArrayOf(p.element)}`;
				encodeView(`e${i}`, view, own, "copy", `parameter '${p.name}'`);
			}
			BoundaryKind.Span => {
				const array = typedArrayOf(p.element);
				const view = `a${i}.base, a${i}.off, a${i}.len, ${array}`;
				const written = p.mode == BoundaryMode.Shared;
				if (written) {
					const bool = p.element == BoundaryKind.Bool;
					copyBacks.push(`__msbCopyBack(e${i}[0], ${view}, ${bool});`);
				}
				const role = written ? "write" : "read";
				encodeView(`e${i}`, view, "", role, `parameter '${p.name}'`);
			}
			_ => {
				argList.push(scalarArg(p.kind, `a${i}`, own));
			}
		}
	}
	if (shared) {
		lines.push("	const hb = [];");
		const names = sharedNames.join(", ");
		const views = sharedViews.join(", ");
		encodes.push(
			`\t\t[${names}] = __msbCopyInViews([${views}], hb, ${quoted(f.name)});`,
		);
		cleanup.push("for (const q of hb) __msbFree(q);");
	}
	const sig = sigs.join(", ");
	const call = `__msbMod._${f.exportSymbol}(${argList.join(", ")})`;
	const guardedCall = (target: string): string => {
		return `try { ${target}${call}; } catch (e) { throw __msb.die(e); }`;
	};
	const body: string[] = match (f.result) {
		BoundaryKind.Void => [guardedCall(""), "if (__msb.dirty) __msb.leave();"],
		BoundaryKind.String | BoundaryKind.Struct | BoundaryKind.Vec => {
			lines.push(f.resultNullable ? "	let r = null;" : "	let r;");
			lines.push(`	const d = __msb.takes.push(${takerOf(f)}) - 1;`);
			cleanup.push("__msb.takes.length = d;");
			[guardedCall(""), "if (__msb.dirty) __msb.leave();", "return r;"]
		},
		_ => {
			const keep = ["let v;", guardedCall("v = "), "if (__msb.dirty) __msb.leave();"];
			if (f.resultNullable) {
				keep.push(
					"return __msbMod._msb_ret_some() !== 0 ? "
						+ `${wireToJsValue(f.result, "v")} : null;`,
				);
			} else {
				keep.push(`return ${wireToJsValue(f.result, "v")};`);
			}
			keep
		},
	};
	const out = [`function ${bundleName}(${sig}) {`];
	if (checked) {
		for (const c of paramChecks(f)) out.push(`	${c}`);
	}
	out.push("	__msb.enter();");
	if (cleanup.length == 0) {
		for (const l of body) out.push(`	${l}`);
	} else {
		for (const l of lines) out.push(l);
		if (encoded.length > 0) {
			const names = encoded.join(", ") + (wasmOwns ? ", sent = false" : "");
			out.push(`\tlet ${names};`);
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

export function jsBindings(
	m: Manifest,
	wasmModuleUrl: string,
	bundleNameOf: (f: BoundaryFunction) => string,
	options: JsBindingOptions,
): JsBindings {
	const modules: JsModuleBindings[] = [];
	const lines: string[][] = [];
	let scratch = false;
	let viewsIn = false;
	let viewsOut = false;
	let anyChecked = false;
	for (const f of m.functions) {
		if (copiesArgsIn(f)) scratch = true;
		if (functionSharesViews(f)) viewsIn = true;
		for (const p of f.params) {
			if (p.kind == BoundaryKind.Callback && callbackSharesViews(p.callback!)) {
				viewsOut = true;
			}
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
		const bundleName = bundleNameOf(f);
		const checked = options.checked(bundleName);
		if (checked) anyChecked = true;
		for (const l of wrapperLines(f, bundleName, checked)) {
			lines[at].push(l);
		}
	}
	for (let i = 0; i < modules.length; i += 1) {
		modules[i].code = lines[i].join("\n") + "\n";
	}
	const views = viewHelpers(viewsIn, viewsOut);
	const prelude = preludeFor(wasmModuleUrl, anyChecked, scratch, views);
	return { prelude, modules };
}
