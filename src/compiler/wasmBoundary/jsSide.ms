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
	for (let i = 0; i < cb.params.length; i += 1) {
		if (i > 0) { names += ", "; args += ", "; }
		names += `x${i}`;
		args += fromWire(cb.params[i], `x${i}`);
	}
	const call = `${target}(${args})`;
	if (cb.result == BoundaryKind.Void) return `(${names}) => { ${call}; }`;
	return `(${names}) => ${toWire(cb.result, call)}`;
}

function wrapperLines(f: BoundaryFunction, bundleName: string): string[] {
	const ids: string[] = [];
	const lines: string[] = [];
	let sig = "";
	let args = "";
	for (let i = 0; i < f.params.length; i += 1) {
		const p: BoundaryParam = f.params[i];
		if (i > 0) { sig += ", "; args += ", "; }
		sig += `a${i}`;
		if (p.kind == BoundaryKind.String) {
			throw new Error(`internal: string parameter '${p.name}' of '${f.name}' reached the wasm side before string crossing exists`);
		}
		if (p.kind == BoundaryKind.Callback) {
			lines.push(`\tconst id${i} = __msb.push(${adapterOf(p.callback!, `a${i}`)});`);
			ids.push(`id${i}`);
			args += `id${i}`;
		} else {
			args += toWire(p.kind, `a${i}`);
		}
	}
	if (f.result == BoundaryKind.String) {
		throw new Error(`internal: string result of '${f.name}' reached the wasm side before string crossing exists`);
	}
	const call = `__msbMod._${f.exportSymbol}(${args})`;
	const ret = f.result == BoundaryKind.Void ? `${call};` : `return ${fromWire(f.result, call)};`;
	const out = [`function ${bundleName}(${sig}) {`];
	if (ids.length == 0) {
		out.push(`\t${ret}`);
	} else {
		for (const l of lines) out.push(l);
		out.push("\ttry {");
		out.push(`\t\t${ret}`);
		out.push("\t} finally {");
		for (const id of ids) out.push(`\t\t__msb.pop(${id});`);
		out.push("\t}");
	}
	out.push("}");
	return out;
}

function quoted(s: string): string {
	return "\"" + s.replaceAll("\\", "\\\\").replaceAll("\"", "\\\"") + "\"";
}

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
