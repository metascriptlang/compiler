import { BoundaryCallback, BoundaryFunction, BoundaryKind, BoundaryMode, BoundaryParam, Manifest, copiesArgsIn, leafLiteral, msTypeOf, unwiredKind } from "./manifest";

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

function fromWire(kind: BoundaryKind, expr: string): string {
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

function toWire(kind: BoundaryKind, expr: string): string {
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

function jsTypeOf(kind: BoundaryKind): string {
	return match (kind) {
		BoundaryKind.Bool => "boolean",
		BoundaryKind.I64 | BoundaryKind.U64 => "bigint",
		BoundaryKind.I8
			| BoundaryKind.I16
			| BoundaryKind.I32
			| BoundaryKind.U8
			| BoundaryKind.U16
			| BoundaryKind.U32
			| BoundaryKind.F32
			| BoundaryKind.F64 => "number",
		BoundaryKind.Void
			| BoundaryKind.Callback
			| BoundaryKind.String
			| BoundaryKind.Struct
			| BoundaryKind.Vec
			| BoundaryKind.Span => { unwiredKind(kind, "JS type check"); },
	};
}

function boundsOf(kind: BoundaryKind): string[] {
	return match (kind) {
		BoundaryKind.I8 => ["-128", "127"],
		BoundaryKind.I16 => ["-32768", "32767"],
		BoundaryKind.I32 => ["-2147483648", "2147483647"],
		BoundaryKind.U8 => ["0", "255"],
		BoundaryKind.U16 => ["0", "65535"],
		BoundaryKind.U32 => ["0", "4294967295"],
		BoundaryKind.I64 => ["-9223372036854775808n", "9223372036854775807n"],
		BoundaryKind.U64 => ["0n", "18446744073709551615n"],
		BoundaryKind.Bool | BoundaryKind.F32 | BoundaryKind.F64 => [],
		BoundaryKind.Void
			| BoundaryKind.Callback
			| BoundaryKind.String
			| BoundaryKind.Struct
			| BoundaryKind.Vec
			| BoundaryKind.Span => { unwiredKind(kind, "value range"); },
	};
}

function elementArgs(kind: BoundaryKind): string {
	const b = boundsOf(kind);
	return `${quoted(jsTypeOf(kind))}, ${b.length == 0 ? "null, null" : b[0] + ", " + b[1]}, ${quoted(msTypeOf(kind))}`;
}

function valueCheck(kind: BoundaryKind, expr: string, at: string): string {
	const b = boundsOf(kind);
	if (b.length == 0) return `__msbType(${expr}, ${quoted(jsTypeOf(kind))}, ${quoted(msTypeOf(kind))}, ${at})`;
	return `__msbInt(${expr}, ${quoted(jsTypeOf(kind))}, ${b[0]}, ${b[1]}, ${quoted(msTypeOf(kind))}, ${at})`;
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
		if (p.kind == BoundaryKind.String) {
			out.push(`__msbType(${x}, "string", "string", ${at(label)});`);
		} else if (p.kind == BoundaryKind.Callback) {
			out.push(`__msbType(${x}, "function", "function", ${at(label)});`);
		} else if (p.kind == BoundaryKind.Struct) {
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
		} else if (p.kind == BoundaryKind.Vec) {
			out.push(`__msbElems(__msbList(${x}, ${quoted(`Vec<${msTypeOf(p.element)}>`)}, ${at(label)}), 0, ${x}.length, ${elementArgs(p.element)}, ${at(label)});`);
		} else if (p.kind == BoundaryKind.Span) {
			out.push(`__msbElems(__msbSpan(${x}, ${quoted(`Span<${msTypeOf(p.element)}>`)}, ${at(label)}).base, ${x}.off, ${x}.len, ${elementArgs(p.element)}, ${at(label)});`);
		} else {
			out.push(valueCheck(p.kind, x, at(label)) + ";");
		}
		if (p.nullable) {
			for (let k = mark; k < out.length; k += 1) out[k] = `if (${x} != null) ${out[k]}`;
		}
	}
	return out;
}

function zeroWire(kind: BoundaryKind): string {
	return kind == BoundaryKind.I64 || kind == BoundaryKind.U64 ? "0n" : "0";
}

function guarded(flag: string, expr: string): string {
	return flag == "" ? expr : `${flag} !== 0 ? ${expr} : null`;
}

function anyOf(a: string, b: string): string {
	return a == "" ? b : b == "" ? a : `${a} || ${b}`;
}

function adapterOf(cb: BoundaryCallback, target: string, resultAt: string | null): string {
	let names = "";
	let args = "";
	let views = "";
	let writesBack = "";
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
			names += `x${w}, x${w + 1}`;
			views += `const s${i} = { base: __msbVecOut(x${w} >>> 0, x${w + 1}, ${t}, ${cb.elements[i] == BoundaryKind.Bool}), off: 0, len: x${w + 1} }; `;
			if (cb.modes[i] == BoundaryMode.Shared) writesBack += `__msbCopyTo(x${w} >>> 0, s${i}.base, 0, x${w + 1}, ${t}); `;
			args += `s${i}`;
			w += 2;
		} else {
			names += `x${w}`;
			args += guarded(flag, fromWire(cb.params[i], `x${w}`));
			w += 1;
		}
	}
	let call = `${target}(${args})`;
	if (resultAt != null && cb.result != BoundaryKind.Void) call = valueCheck(cb.result, call, resultAt);
	const body =cb.result == BoundaryKind.Void ? `${call};` : `return ${toWire(cb.result, call)};`;
	if (writesBack != "") return `(${names}) => { ${views}try { ${body} } finally { ${writesBack}} }`;
	if (views != "") return `(${names}) => { ${views}${body} }`;
	if (cb.result == BoundaryKind.Void) return `(${names}) => { ${call}; }`;
	return `(${names}) => ${toWire(cb.result, call)}`;
}

function forwardsUnchanged(cb: BoundaryCallback, adapter: string, target: string): boolean {
	const names: string[] = [];
	for (let i = 0; i < cb.params.length; i += 1) names.push(`x${i}`);
	const list = names.join(", ");
	const call = `${target}(${list})`;
	return adapter == `(${list}) => ${call}` || adapter == `(${list}) => { ${call}; }`;
}

function typedArrayOf(kind: BoundaryKind): string {
	return match (kind) {
		BoundaryKind.Bool | BoundaryKind.U8 => "Uint8Array",
		BoundaryKind.I8 => "Int8Array",
		BoundaryKind.I16 => "Int16Array",
		BoundaryKind.I32 => "Int32Array",
		BoundaryKind.U16 => "Uint16Array",
		BoundaryKind.U32 => "Uint32Array",
		BoundaryKind.I64 => "BigInt64Array",
		BoundaryKind.U64 => "BigUint64Array",
		BoundaryKind.F32 => "Float32Array",
		BoundaryKind.F64 => "Float64Array",
		BoundaryKind.Void
			| BoundaryKind.Callback
			| BoundaryKind.String
			| BoundaryKind.Struct
			| BoundaryKind.Vec
			| BoundaryKind.Span => { unwiredKind(kind, "typed array"); },
	};
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
			values.push(guarded(flag, fromWire(leaf.kind, `x${w}`)));
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

function wrapperLines(f: BoundaryFunction, bundleName: string, options: JsBindingOptions): string[] {
	const cleanup: string[] = [];
	const copyBacks: string[] = [];
	const lines: string[] = [];
	const encoded: string[] = [];
	const encodes: string[] = [];
	const sigs: string[] = [];
	const argList: string[] = [];
	let wasmOwns = false;
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
	for (let i = 0; i < f.params.length; i += 1) {
		const p: BoundaryParam = f.params[i];
		sigs.push(`a${i}`);
		const own = p.nullable ? `a${i} == null` : "";
		if (p.nullable) argList.push(`${own} ? 0 : 1`);
		if (p.kind == BoundaryKind.String) {
			encode(`e${i}`, `a${i}`, "__msbEncOwned", true, own);
		} else if (p.kind == BoundaryKind.Callback) {
			let resultAt: string | null = null;
			if (options.checked) resultAt = `${quoted(f.name)}, ${quoted(`result of callback '${p.name}'`)}`;
			const target = `a${i}`;
			const adapter = adapterOf(p.callback!, target, resultAt);
			lines.push(`	const id${i} = __msb.push(${forwardsUnchanged(p.callback!, adapter, target) ? target : adapter});`);
			cleanup.push(`__msb.pop(id${i});`);
			argList.push(`id${i}`);
		} else if (p.kind == BoundaryKind.Struct) {
			for (let j = 0; j < p.leaves.length; j += 1) {
				const leaf = p.leaves[j];
				const expr = `a${i}.${leaf.path.join(".")}`;
				const absent = anyOf(own, leaf.nullable ? `${expr} == null` : "");
				if (leaf.nullable) argList.push(`${absent} ? 0 : 1`);
				if (leaf.kind == BoundaryKind.String) encode(`e${i}_${j}`, expr, "__msbEncOwned", true, absent);
				else if (absent == "") argList.push(toWire(leaf.kind, expr));
				else argList.push(`${absent} ? ${zeroWire(leaf.kind)} : ${toWire(leaf.kind, expr)}`);
			}
		} else if (p.kind == BoundaryKind.Vec) {
			encode(`e${i}`, `a${i}, 0, a${i}.length, ${typedArrayOf(p.element)}`, "__msbCopyIn", false, own);
		} else if (p.kind == BoundaryKind.Span) {
			const view = `a${i}.base, a${i}.off, a${i}.len, ${typedArrayOf(p.element)}`;
			if (p.mode == BoundaryMode.Shared) copyBacks.push(`__msbCopyBack(e${i}[0], ${view}, ${p.element == BoundaryKind.Bool});`);
			encode(`e${i}`, view, "__msbCopyIn", false, "");
		} else if (p.nullable) {
			argList.push(`${own} ? ${zeroWire(p.kind)} : ${toWire(p.kind, `a${i}`)}`);
		} else {
			argList.push(toWire(p.kind, `a${i}`));
		}
	}
	const sig = sigs.join(", ");
	const call = `__msbMod._${f.exportSymbol}(${argList.join(", ")})`;
	let body: string[] = [];
	if (f.result == BoundaryKind.Void) {
		body = [`${call};`];
	} else if (f.result == BoundaryKind.String || f.result == BoundaryKind.Struct || f.result == BoundaryKind.Vec) {
		lines.push(f.resultNullable ? "	let r = null;" : "	let r;");
		lines.push(`	const d = __msb.takes.push(${takerOf(f)}) - 1;`);
		cleanup.push("__msb.takes.length = d;");
		body = [`${call};`, "return r;"];
	} else if (f.resultNullable) {
		body = [`const v = ${call};`, `return __msbMod._msb_ret_some() !== 0 ? ${fromWire(f.result, "v")} : null;`];
	} else {
		body = [`return ${fromWire(f.result, call)};`];
	}
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

function quoted(s: string): string {
	return "\"" + s.replaceAll("\\", "\\\\").replaceAll("\"", "\\\"") + "\"";
}

const GLUE = [
	"const __msbTe = new TextEncoder();",
	"const __msbTd = new TextDecoder('utf-8', { ignoreBOM: true });",
	"function __msbHeapAlloc(n) {",
	"\tconst p = n > 4294967295 ? 0 : __msbMod._malloc(n);",
	"\tif (p === 0) throw new RangeError(\"wasm heap exhausted: cannot copy \" + n + \" bytes into wasm memory\");",
	"\treturn p;",
	"}",
	"function __msbAlloc(n) {",
	"\tconst room = __msbEnd - __msbTop;",
	"\tif (n <= room) {",
	"\t\tconst a = n + 15 & -16;",
	"\t\tif (a <= room) {",
	"\t\t\tconst q = __msbTop;",
	"\t\t\t__msbTop = q + a;",
	"\t\t\treturn q;",
	"\t\t}",
	"\t}",
	"\treturn __msbHeapAlloc(n);",
	"}",
	"function __msbFree(p) {",
	"\tif (p < __msbBase || p >= __msbEnd) __msbMod._free(p);",
	"}",
	"function __msbInRange(a, off, n) {",
	"\tif (!(off >= 0 && n >= 0 && off + n <= a.length)) throw new RangeError(\"Span out of range of its array: offset \" + off + \", length \" + n + \", array length \" + a.length + \" (was the array resized while lent?)\");",
	"}",
	"function __msbCopyIn(a, off, n, T) {",
	"\t__msbInRange(a, off, n);",
	"\tconst p = __msbAlloc(n * T.BYTES_PER_ELEMENT || 1);",
	"\t__msbCopyTo(p, a, off, n, T);",
	"\treturn [p, n];",
	"}",
	"function __msbCopyTo(p, a, off, n, T) {",
	"\t__msbInRange(a, off, n);",
	"\tconst v = new T(__msbMod.HEAPU8.buffer, p, n);",
	"\tif (ArrayBuffer.isView(a)) v.set(a.subarray(off, off + n));",
	"\telse for (let i = 0; i < n; i++) v[i] = a[off + i];",
	"}",
	"function __msbCopyBack(p, a, off, n, T, bool) {",
	"\t__msbInRange(a, off, n);",
	"\tconst v = new T(__msbMod.HEAPU8.buffer, p, n);",
	"\tif (!bool && n !== 0 && ArrayBuffer.isView(a)) a.set(v, off);",
	"\telse for (let i = 0; i < n; i++) a[off + i] = bool ? v[i] !== 0 : v[i];",
	"}",
	"function __msbVecOut(p, n, T, bool) {",
	"\tconst v = new T(__msbMod.HEAPU8.buffer, p, n);",
	"\tconst r = new Array(n);",
	"\tfor (let i = 0; i < n; i++) r[i] = bool ? v[i] !== 0 : v[i];",
	"\treturn r;",
	"}",
	"function __msbSeal(h, p, n) {",
	"\th[p] = n; h[p + 1] = n >>> 8; h[p + 2] = n >>> 16; h[p + 3] = n >>> 24;",
	"\th[p + 4] = 0; h[p + 5] = 0; h[p + 6] = 0; h[p + 7] = 0;",
	"\th[p + 8 + n] = 0;",
	"\treturn [p, n];",
	"}",
	"function __msbEncAt(s, own) {",
	"\tconst n = s.length;",
	"\tif (own && n === 0) return [0, 0];",
	"\tconst hd = own ? 8 : 0;",
	"\tlet i = 0;",
	"\twhile (i < n && s.charCodeAt(i) < 128) i++;",
	"\tif (i === n) {",
	"\t\tconst p = __msbHeapAlloc(own ? n + 9 : n || 1);",
	"\t\tconst h = __msbMod.HEAPU8;",
	"\t\t__msbTe.encodeInto(s, h.subarray(p + hd, p + hd + n));",
	"\t\treturn own ? __msbSeal(h, p, n) : [p, n];",
	"\t}",
	"\tlet cap = n * 3;",
	"\tif (n > 4096) {",
	"\t\tcap = i;",
	"\t\tfor (let j = i; j < n; j++) {",
	"\t\t\tconst c = s.charCodeAt(j);",
	"\t\t\tif (c < 128) cap++;",
	"\t\t\telse if (c < 2048) cap += 2;",
	"\t\t\telse if (c >= 0xd800 && c < 0xdc00 && j + 1 < n && (s.charCodeAt(j + 1) & 0xfc00) === 0xdc00) { cap += 4; j++; }",
	"\t\t\telse cap += 3;",
	"\t\t}",
	"\t}",
	"\tconst p = __msbHeapAlloc(own ? cap + 9 : cap);",
	"\tconst h = __msbMod.HEAPU8;",
	"\tlet o = p + hd;",
	"\tfor (i = 0; i < n; i++) {",
	"\t\tlet c = s.charCodeAt(i);",
	"\t\tif (c < 128) h[o++] = c;",
	"\t\telse if (c < 2048) { h[o++] = 192 | c >> 6; h[o++] = 128 | c & 63; }",
	"\t\telse if (c >= 0xd800 && c < 0xdc00 && i + 1 < n && (s.charCodeAt(i + 1) & 0xfc00) === 0xdc00) {",
	"\t\t\tc = 0x10000 + ((c & 1023) << 10 | s.charCodeAt(++i) & 1023);",
	"\t\t\th[o++] = 240 | c >> 18; h[o++] = 128 | c >> 12 & 63; h[o++] = 128 | c >> 6 & 63; h[o++] = 128 | c & 63;",
	"\t\t} else { h[o++] = 224 | c >> 12; h[o++] = 128 | c >> 6 & 63; h[o++] = 128 | c & 63; }",
	"\t}",
	"\tif (o - p - hd > cap) throw new Error(\"internal: string encoder wrote \" + (o - p - hd) + \" bytes into a block of \" + cap);",
	"\treturn own ? __msbSeal(h, p, o - p - hd) : [p, o - p];",
	"}",
	"function __msbEnc(s) {",
	"\treturn __msbEncAt(s, false);",
	"}",
	"function __msbEncOwned(s) {",
	"\treturn __msbEncAt(s, true);",
	"}",
	"function __msbDecLoop(h, p, end) {",
	"\tlet r = \"\";",
	"\twhile (p < end) {",
	"\t\tconst x = h[p];",
	"\t\tif (x < 128) { r += String.fromCharCode(x); p++; }",
	"\t\telse if (x < 224) { r += String.fromCharCode((x & 31) << 6 | h[p + 1] & 63); p += 2; }",
	"\t\telse if (x < 240) { r += String.fromCharCode((x & 15) << 12 | (h[p + 1] & 63) << 6 | h[p + 2] & 63); p += 3; }",
	"\t\telse {",
	"\t\t\tconst c = ((x & 7) << 18 | (h[p + 1] & 63) << 12 | (h[p + 2] & 63) << 6 | h[p + 3] & 63) - 65536;",
	"\t\t\tr += String.fromCharCode(55296 + (c >> 10), 56320 + (c & 1023)); p += 4;",
	"\t\t}",
	"\t}",
	"\treturn r;",
	"}",
	"function __msbDec(p, len) {",
	"\tconst h = __msbMod.HEAPU8;",
	"\tif (len <= 16) return __msbDecLoop(h, p, p + len);",
	"\tconst e = p + len;",
	"\tconst s = __msbTd.decode(h.subarray(p, e));",
	"\tif (s.indexOf(\"\\uFFFD\") < 0) return s;",
	"\tfor (let i = p; i + 1 < e; i++) {",
	"\t\tif (h[i] === 0xed && h[i + 1] >= 0xa0) return __msbDecLoop(h, p, e);",
	"\t}",
	"\treturn s;",
	"}",
];

const CHECK_GLUE = [
	"function __msbBad(f, p, t, v) {",
	"\treturn new TypeError(f + \": \" + p + \" expected \" + t + \", found \" + (v === null ? \"null\" : Array.isArray(v) ? \"array\" : typeof v));",
	"}",
	"function __msbType(v, k, t, f, p) {",
	"\tif (typeof v !== k || v === null) throw __msbBad(f, p, t, v);",
	"\treturn v;",
	"}",
	"function __msbInt(v, k, lo, hi, t, f, p) {",
	"\tif (typeof v !== k) throw __msbBad(f, p, t, v);",
	"\tif (v < lo || v > hi || (k === \"number\" && !Number.isInteger(v))) throw new RangeError(f + \": \" + p + \" expected \" + t + \", got \" + v);",
	"\treturn v;",
	"}",
	"function __msbList(v, t, f, p) {",
	"\tif (typeof v !== \"object\" || v === null || !Number.isInteger(v.length) || v.length < 0) throw __msbBad(f, p, t, v);",
	"\treturn v;",
	"}",
	"function __msbSpan(v, t, f, p) {",
	"\t__msbType(v, \"object\", t, f, p);",
	"\t__msbList(v.base, \"array\", f, p + \" base\");",
	"\tif (!Number.isInteger(v.off) || !Number.isInteger(v.len)) throw new TypeError(f + \": \" + p + \" expected \" + t + \" with integer off and len, got off \" + v.off + \" len \" + v.len);",
	"\treturn v;",
	"}",
	"function __msbElems(v, off, n, k, lo, hi, t, f, p) {",
	"\tconst end = Math.min(off + n, v.length);",
	"\tfor (let i = Math.max(off, 0); i < end; i++) {",
	"\t\tconst x = v[i];",
	"\t\tif (typeof x === k && (lo === null || (x >= lo && x <= hi && (k !== \"number\" || Number.isInteger(x))))) continue;",
	"\t\tif (lo === null) __msbType(x, k, t, f, p + \" element \" + (i - off));",
	"\t\t__msbInt(x, k, lo, hi, t, f, p + \" element \" + (i - off));",
	"\t}",
	"\treturn v;",
	"}",
];

const SCRATCH_BYTES = 16384;

function scratchLines(used: boolean): string[] {
	if (!used) return ["const __msbBase = 0;", "const __msbEnd = 0;", "let __msbTop = 0;"];
	return [
		`const __msbBase = __msbMod._malloc(${SCRATCH_BYTES});`,
		`const __msbEnd = __msbBase === 0 ? 0 : __msbBase + ${SCRATCH_BYTES};`,
		"let __msbTop = __msbBase;",
	];
}

const SLOT_BITS: int32 = 16;
const SLOT_CAP: int32 = 1 << SLOT_BITS;
const SLOT_MASK: int32 = SLOT_CAP - 1;
const GEN_MASK: int32 = (1 << (31 - SLOT_BITS)) - 1;

function preludeFor(wasmModuleUrl: string, options: JsBindingOptions, scratch: boolean): string {
	return [
		"const __msb = (() => {",
		"\tconst vals = [];",
		"\tconst gens = [];",
		"\tconst free = [];",
		"\tlet dead = false;",
		"\tlet cause;",
		"\treturn {",
		"\t\tpush(f) {",
		"\t\t\tlet s = free.pop();",
		"\t\t\tif (s === undefined) {",
		`\t\t\t\tif (vals.length >= ${SLOT_CAP}) throw new RangeError("boundary table full: ${SLOT_CAP} live entries");`,
		"\t\t\t\ts = vals.length;",
		"\t\t\t\tvals.push(undefined);",
		"\t\t\t\tgens.push(0);",
		"\t\t\t}",
		"\t\t\tvals[s] = f;",
		`\t\t\treturn (gens[s] << ${SLOT_BITS}) | s;`,
		"\t\t},",
		"\t\tpop(id) {",
		`\t\t\tconst s = id & ${SLOT_MASK};`,
		`\t\t\tif (vals[s] === undefined || gens[s] !== id >>> ${SLOT_BITS}) throw new Error("boundary entry released twice");`,
		"\t\t\tvals[s] = undefined;",
		`\t\t\tgens[s] = (gens[s] + 1) & ${GEN_MASK};`,
		"\t\t\tfree.push(s);",
		"\t\t},",
		"\t\ttakes: [],",
		"\t\tcb(id) {",
		`\t\t\tconst s = id & ${SLOT_MASK};`,
		`\t\t\tif (vals[s] === undefined || gens[s] !== id >>> ${SLOT_BITS}) throw new Error("callback used after its call returned");`,
		"\t\t\treturn vals[s];",
		"\t\t},",
		"\t\tenter() { if (dead) throw new Error(\"the wasm half cannot run again: a JS exception crossed its frames\", { cause }); },",
		"\t\tdie(e) { if (!dead) { dead = true; cause = e; } return e; },",
		"\t};",
		"})();",
		(options.checked ? GLUE.concat(CHECK_GLUE) : GLUE).join("\n"),
		`const __msbMod = await (await import(${quoted(wasmModuleUrl)})).default({ msb: __msb });`,
		"__msbMod._MsMain();",
		...scratchLines(scratch),
		"",
	].join("\n");
}

export function jsBindings(m: Manifest, wasmModuleUrl: string, bundleNameOf: (f: BoundaryFunction) => string, options: JsBindingOptions): JsBindings {
	const modules: JsModuleBindings[] = [];
	const lines: string[][] = [];
	let scratch = false;
	for (const f of m.functions) {
		if (copiesArgsIn(f)) scratch = true;
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
	return { prelude: preludeFor(wasmModuleUrl, options, scratch), modules };
}
