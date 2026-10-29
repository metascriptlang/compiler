import { BoundaryCallback, BoundaryFunction, BoundaryKind, BoundaryParam, Manifest } from "./manifest";

export interface JsModuleBindings {
	modulePath: string;
	code: string;
}

export interface JsBindings {
	prelude: string;
	modules: JsModuleBindings[];
}

function fromWire(kind: BoundaryKind, expr: string): string {
	switch (kind) {
		case BoundaryKind.Bool: return `${expr} !== 0`;
		case BoundaryKind.I8: return `(${expr} << 24) >> 24`;
		case BoundaryKind.I16: return `(${expr} << 16) >> 16`;
		case BoundaryKind.U8: return `${expr} & 255`;
		case BoundaryKind.U16: return `${expr} & 65535`;
		case BoundaryKind.U32: return `${expr} >>> 0`;
		case BoundaryKind.U64: return `BigInt.asUintN(64, ${expr})`;
		default: return expr;
	}
}

function toWire(kind: BoundaryKind, expr: string): string {
	return kind == BoundaryKind.Bool ? `(${expr} ? 1 : 0)` : expr;
}

function adapterOf(cb: BoundaryCallback, target: string): string {
	let names = "";
	let args = "";
	let w = 0;
	for (let i = 0; i < cb.params.length; i += 1) {
		if (i > 0) args += ", ";
		if (w > 0) names += ", ";
		if (cb.params[i] == BoundaryKind.String) {
			names += `x${w}, x${w + 1}`;
			args += `__msbDec(x${w}, x${w + 1})`;
			w += 2;
		} else {
			names += `x${w}`;
			args += fromWire(cb.params[i], `x${w}`);
			w += 1;
		}
	}
	const call = `${target}(${args})`;
	if (cb.result == BoundaryKind.Void) return `(${names}) => { ${call}; }`;
	return `(${names}) => ${toWire(cb.result, call)}`;
}

function wrapperLines(f: BoundaryFunction, bundleName: string): string[] {
	const cleanup: string[] = [];
	const lines: string[] = [];
	const encoded: string[] = [];
	const encodes: string[] = [];
	let sig = "";
	let args = "";
	for (let i = 0; i < f.params.length; i += 1) {
		const p: BoundaryParam = f.params[i];
		if (i > 0) { sig += ", "; args += ", "; }
		sig += `a${i}`;
		if (p.kind == BoundaryKind.String) {
			encoded.push(`e${i}`);
			encodes.push(`		e${i} = __msbEnc(a${i});`);
			cleanup.push(`if (e${i}) __msbMod._free(e${i}[0]);`);
			args += `e${i}[0], e${i}[1]`;
		} else if (p.kind == BoundaryKind.Callback) {
			lines.push(`	const id${i} = __msb.push(${adapterOf(p.callback!, `a${i}`)});`);
			cleanup.push(`__msb.pop(id${i});`);
			args += `id${i}`;
		} else {
			args += toWire(p.kind, `a${i}`);
		}
	}
	const call = `__msbMod._${f.exportSymbol}(${args})`;
	let ret = `return ${fromWire(f.result, call)};`;
	if (f.result == BoundaryKind.Void) ret = `${call};`;
	if (f.result == BoundaryKind.String) ret = `return __msbDec(${call}, __msbMod._msb_ret_len());`;
	const out = [`function ${bundleName}(${sig}) {`];
	if (cleanup.length == 0) {
		out.push(`	${ret}`);
	} else {
		for (const l of lines) out.push(l);
		if (encoded.length > 0) out.push(`	let ${encoded.join(", ")};`);
		out.push("	try {");
		for (const l of encodes) out.push(l);
		out.push(`		${ret}`);
		out.push("	} finally {");
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
	"const __msbTd = new TextDecoder();",
	"function __msbAlloc(n) {",
	"\tconst p = __msbMod._malloc(n);",
	"\tif (p === 0) throw new RangeError(\"wasm heap exhausted: cannot copy a string of \" + n + \" bytes into wasm memory\");",
	"\treturn p;",
	"}",
	"function __msbEnc(s) {",
	"\tconst n = s.length;",
	"\tlet i = 0;",
	"\twhile (i < n && s.charCodeAt(i) < 128) i++;",
	"\tif (i === n) {",
	"\t\tconst p = __msbAlloc(n || 1);",
	"\t\t__msbTe.encodeInto(s, __msbMod.HEAPU8.subarray(p, p + n));",
	"\t\treturn [p, n];",
	"\t}",
	"\tconst p = __msbAlloc(n * 3);",
	"\tconst h = __msbMod.HEAPU8;",
	"\tlet o = p;",
	"\tfor (i = 0; i < n; i++) {",
	"\t\tlet c = s.charCodeAt(i);",
	"\t\tif (c < 128) h[o++] = c;",
	"\t\telse if (c < 2048) { h[o++] = 192 | c >> 6; h[o++] = 128 | c & 63; }",
	"\t\telse if (c >= 0xd800 && c < 0xdc00 && i + 1 < n && (s.charCodeAt(i + 1) & 0xfc00) === 0xdc00) {",
	"\t\t\tc = 0x10000 + ((c & 1023) << 10 | s.charCodeAt(++i) & 1023);",
	"\t\t\th[o++] = 240 | c >> 18; h[o++] = 128 | c >> 12 & 63; h[o++] = 128 | c >> 6 & 63; h[o++] = 128 | c & 63;",
	"\t\t} else { h[o++] = 224 | c >> 12; h[o++] = 128 | c >> 6 & 63; h[o++] = 128 | c & 63; }",
	"\t}",
	"\treturn [p, o - p];",
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
	"\tfor (let i = p, e = p + len; i < e; i++) {",
	"\t\tif (h[i] === 0xed && h[i + 1] >= 0xa0) return __msbDecLoop(h, p, e);",
	"\t}",
	"\treturn __msbTd.decode(h.subarray(p, p + len));",
	"}",
];

function preludeFor(wasmModuleUrl: string): string {
	return [
		"const __msb = (() => {",
		"\tconst live = new Map();",
		"\tlet next = 0;",
		"\treturn {",
		"\t\tpush(f) { const id = next; next = (next + 1) | 0; live.set(id, f); return id; },",
		"\t\tpop(id) { live.delete(id); },",
		"\t\tcb(id, ...a) {",
		"\t\t\tconst f = live.get(id);",
		"\t\t\tif (f === undefined) throw new Error(\"callback used after its call returned\");",
		"\t\t\treturn f(...a);",
		"\t\t},",
		"\t};",
		"})();",
		"globalThis.__msb = __msb;",
		GLUE.join("
"),
		`const __msbMod = await (await import(${quoted(wasmModuleUrl)})).default();`,
		"__msbMod._MsMain();",
		"",
	].join("\n");
}

export function jsBindings(m: Manifest, wasmModuleUrl: string, bundleNameOf: (f: BoundaryFunction) => string): JsBindings {
	const modules: JsModuleBindings[] = [];
	const lines: string[][] = [];
	for (const f of m.functions) {
		let at = -1;
		for (let i = 0; i < modules.length; i += 1) {
			if (modules[i].modulePath == f.modulePath) at = i;
		}
		if (at < 0) {
			modules.push({ modulePath: f.modulePath, code: "" });
			lines.push([]);
			at = modules.length - 1;
		}
		for (const l of wrapperLines(f, bundleNameOf(f))) lines[at].push(l);
	}
	for (let i = 0; i < modules.length; i += 1) modules[i].code = lines[i].join("\n") + "\n";
	return { prelude: preludeFor(wasmModuleUrl), modules };
}
