// Reads emitted C as text: functions split at a column-0 signature and a lone `}`, structs with their pointer fields.
import { readDir, readFile } from "std/fs";

const NOT_TYPES = ["return", "goto", "else", "case", "const", "struct", "sizeof"];

export interface CFunction {
	name: string;
	file: string;
	line: int32;
	params: string;
	body: string[];
}

export interface CDecl {
	type: string;
	name: string;
}

export class CProgram {
	fns: HashMap<string, CFunction> = new HashMap<string, CFunction>();
	// struct -> its pointer fields -> their types; a struct held by value is a copy, never another thread's cell
	structs: HashMap<string, HashMap<string, string>> = new HashMap<string, HashMap<string, string>>();
}

export function isIdentChar(c: string): boolean {
	return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_";
}

export function isIdentStart(c: string): boolean {
	return isIdentChar(c) && !(c >= "0" && c <= "9");
}

export function identAt(s: string, at: int32): string {
	let end = at;
	while (end < s.length && isIdentChar(s.charAt(end))) end += 1;
	return s.slice(at, end);
}

export function skipSpaces(s: string, at: int32): int32 {
	let i = at;
	while (i < s.length && (s.charAt(i) == " " || s.charAt(i) == "\t")) i += 1;
	return i;
}

export function hasPrefix(name: string, prefixes: string[]): boolean {
	for (const p of prefixes) {
		if (name.startsWith(p)) return true;
	}
	return false;
}

// `T* v`, `T v` or `const T* v` at the start of a trimmed fragment, followed by `=`, `;`, `,`, `)`, `[` or its end.
export function declOf(text: string): CDecl | null {
	let s = text.trim();
	if (s.startsWith("const ")) s = s.slice(6).trim();
	if (s.length == 0 || !isIdentStart(s.charAt(0))) return null;
	const type = identAt(s, 0);
	if (NOT_TYPES.includes(type)) return null;
	let i = skipSpaces(s, type.length);
	while (i < s.length && s.charAt(i) == "*") i = skipSpaces(s, i + 1);
	if (i >= s.length || !isIdentStart(s.charAt(i))) return null;
	const name = identAt(s, i);
	const after = skipSpaces(s, i + name.length);
	const next = after < s.length ? s.charAt(after) : "";
	if (next != "" && next != "=" && next != ";" && next != "," && next != ")" && next != "[") return null;
	return { type, name };
}

export function definedName(line: string): string {
	if (line.length == 0 || !isIdentStart(line.charAt(0)) || !line.trimEnd().endsWith("{") || line.includes(";")) return "";
	const open = line.indexOf("(");
	if (open <= 0) return "";
	let end = open;
	while (end > 0 && line.charAt(end - 1) == " ") end -= 1;
	let start = end;
	while (start > 0 && isIdentChar(line.charAt(start - 1))) start -= 1;
	return start < end && start > 0 ? line.slice(start, end) : "";
}

export function definedStruct(line: string): string {
	let s = line.trimEnd();
	if (s.startsWith("typedef ")) s = s.slice(8);
	if (!s.startsWith("struct ") || !s.endsWith("{") || s.includes(";")) return "";
	return identAt(s, skipSpaces(s, 7));
}

export function collect(dir: string, into: CProgram): void {
	for (const name of readDir(dir)) {
		if (!name.endsWith(".c")) continue;
		const text = readFile(`${dir}/${name}`);
		if (!text.ok) continue;
		const lines = text.value.split("\n");
		let i = 0;
		while (i < lines.length) {
			const st = definedStruct(lines[i]);
			if (st != "") {
				const fields = new HashMap<string, string>();
				let j = i + 1;
				while (j < lines.length && !lines[j].startsWith("}")) {
					const d = lines[j].includes("*") ? declOf(lines[j]) : null;
					if (d != null) fields.set(d.name, d.type);
					j += 1;
				}
				if (!into.structs.has(st)) into.structs.set(st, fields);
				i = j + 1;
				continue;
			}
			const fn = definedName(lines[i]);
			if (fn == "") { i += 1; continue; }
			const close = lines[i].lastIndexOf(")");
			const params = close > lines[i].indexOf("(") ? lines[i].slice(lines[i].indexOf("(") + 1, close) : "";
			let j = i + 1;
			while (j < lines.length && lines[j] != "}") j += 1;
			into.fns.set(fn, { name: fn, file: `${dir}/${name}`, line: i + 1, params, body: lines.slice(i + 1, j) });
			i = j + 1;
		}
	}
}

export function callArguments(line: string, open: int32): string[] {
	const args: string[] = [];
	let depth = 0;
	let start = open + 1;
	for (let i = open + 1; i < line.length; i += 1) {
		const c = line.charAt(i);
		if (c == "(") depth += 1;
		else if (c == ")" && depth > 0) depth -= 1;
		else if ((c == "," || c == ")") && depth == 0) {
			args.push(line.slice(start, i));
			if (c == ")") return args;
			start = i + 1;
		}
	}
	return args;
}
