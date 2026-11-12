import { hydrating } from "./claim";

const values = new Map<string, string>();
const errors = new Map<string, string>();
const modules = new Map<string, string>();

when (js) {
	extern function jsHas(table: cstring, id: cstring): boolean from
		"((t, i) => { const h = globalThis._$HY; return h !== undefined && h[t] !== undefined && Object.hasOwn(h[t], i); })(#, #)";
	extern function jsRead(table: cstring, id: cstring): string from
		"(globalThis._$$HY[#][#])";
	extern function jsWrite(table: cstring, id: cstring, value: cstring): void from
		"((t, i, v) => { const h = (globalThis._$HY ??= { r: {}, e: {} }); h[t] ??= {}; h[t][i] = v; })(#, #, #)";
	extern function jsDrop(table: cstring, id: cstring): void from
		"((t, i) => { const h = globalThis._$HY; if (h !== undefined && h[t] !== undefined) delete h[t][i]; })(#, #)";
	extern function jsModules(): string from
		"(Object.values((globalThis._$$HY ?? {}).m ?? {}).join(\"\\n\"))";
	extern function jsClear(): void from "(delete globalThis._$$HY)";
}

function has(table: string, id: string): boolean {
	if (!hydrating()) { return false; }
	when (js) {
		return jsHas(table, id);
	} else {
		return (table === "r" ? values : errors).has(id);
	}
}

function read(table: string, id: string): string {
	if (!has(table, id)) {
		throw new Error("hydrate: the page has no " + (table === "r" ? "record" : "error record") + " for " + id + " to read");
	}
	when (js) {
		return jsRead(table, id);
	} else {
		return (table === "r" ? values : errors).get(id) as string;
	}
}

export function hasRecord(id: string): boolean {
	return has("r", id);
}

export function hasError(id: string): boolean {
	return has("e", id);
}

export function readRecord<T>(id: string): T {
	const decoded = JSON.parse<T>(read("r", id));
	if (!decoded.ok) { throw new Error("hydrate: the record for " + id + " does not decode: " + decoded.error); }
	return decoded.value;
}

export function readError(id: string): string {
	return read("e", id);
}

export function putRecord(id: string, json: string): void {
	when (js) {
		jsWrite("r", id, json);
	} else {
		values.set(id, json);
	}
}

export function putError(id: string, message: string): void {
	when (js) {
		jsWrite("e", id, message);
	} else {
		errors.set(id, message);
	}
}

export function putModule(id: string, key: string): void {
	when (js) {
		jsWrite("m", id, key);
	} else {
		modules.set(id, key);
	}
}

export function moduleKeys(): string[] {
	const keys: string[] = [];
	when (js) {
		const listed: string = jsModules();
		for (const key of listed === "" ? [] : listed.split("\n")) { if (!keys.includes(key)) { keys.push(key); } }
	} else {
		for (const key of modules.values()) { if (!keys.includes(key)) { keys.push(key); } }
	}
	return keys;
}

export function dropRecord(id: string): void {
	when (js) {
		jsDrop("r", id);
		jsDrop("e", id);
	} else {
		values.delete(id);
		errors.delete(id);
	}
}

export function clearRecords(): void {
	when (js) {
		jsClear();
	} else {
		values.clear();
		errors.clear();
		modules.clear();
	}
}

function hex4(code: int32): string {
	return ("0000" + code.toString(16)).slice(-4);
}

export function scriptLiteral(text: string): string {
	let out = "";
	let last = 0;
	for (let i = 0; i < text.length; i += 1) {
		const c = text.charCodeAt(i);
		if (c >= 32 && c !== 34 && c !== 60 && c !== 92 && c !== 0x2028 && c !== 0x2029) { continue; }
		const e = c === 34 ? "\\\"" : c === 92 ? "\\\\" : "\\u" + hex4(c);
		out = out + text.slice(last, i) + e;
		last = i + 1;
	}
	return last === 0 ? text : out + text.slice(last);
}
