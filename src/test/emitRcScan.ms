// Emit workers read the checked program's Types and Symbols at once, so the code an emit job
// reaches takes no rc op on them (V5).
import { argv, cwd, execFileCapture, exit } from "std/process";
import { ensureDir, exists, readDir, readFile, removeAll } from "std/fs";

const ROOT_PREFIX = "emitModuleJob__";
const ROOT_SUFFIX = "compileOms_u0";
const RC_OPS = ["msIncrefCyclic(", "msDecrefCyclic(", "msIncref(", "msDecref("];
const CELL_TYPES = ["Type__", "Symbol__"];

interface CFunction {
	name: string;
	file: string;
	line: int32;
	params: string;
	body: string[];
}

interface RcOp {
	fn: string;
	cell: string;
	at: string;
	text: string;
}

function isIdentChar(c: string): boolean {
	return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_";
}

function isIdentStart(c: string): boolean {
	return isIdentChar(c) && !(c >= "0" && c <= "9");
}

function identAt(s: string, at: int32): string {
	let end = at;
	while (end < s.length && isIdentChar(s.charAt(end))) end += 1;
	return s.slice(at, end);
}

function skipSpaces(s: string, at: int32): int32 {
	let i = at;
	while (i < s.length && (s.charAt(i) == " " || s.charAt(i) == "\t")) i += 1;
	return i;
}

function definedName(line: string): string {
	if (line.length == 0 || !isIdentStart(line.charAt(0)) || !line.trimEnd().endsWith("{") || line.includes(";")) return "";
	const open = line.indexOf("(");
	if (open <= 0) return "";
	let end = open;
	while (end > 0 && line.charAt(end - 1) == " ") end -= 1;
	let start = end;
	while (start > 0 && isIdentChar(line.charAt(start - 1))) start -= 1;
	return start < end && start > 0 ? line.slice(start, end) : "";
}

function collectFunctions(dir: string, into: HashMap<string, CFunction>): void {
	for (const name of readDir(dir)) {
		if (!name.endsWith(".c")) continue;
		const text = readFile(`${dir}/${name}`);
		if (!text.ok) continue;
		const lines = text.value.split("\n");
		let i = 0;
		while (i < lines.length) {
			const fn = definedName(lines[i]);
			if (fn == "") { i += 1; continue; }
			const close = lines[i].lastIndexOf(")");
			const params = close > lines[i].indexOf("(") ? lines[i].slice(lines[i].indexOf("(") + 1, close) : "";
			let j = i + 1;
			while (j < lines.length && lines[j] != "}") j += 1;
			into.set(fn, { name: fn, file: `${dir}/${name}`, line: i + 1, params, body: lines.slice(i + 1, j) });
			i = j + 1;
		}
	}
}

function reachedFromEmitJob(fns: HashMap<string, CFunction>): string[] {
	let root = "";
	for (const name of fns.keys()) {
		if (name.startsWith(ROOT_PREFIX) && name.endsWith(ROOT_SUFFIX)) root = name;
	}
	if (root == "") {
		console.log(`FAIL self-host: the emitted C defines no ${ROOT_PREFIX}*${ROOT_SUFFIX}, so the rc scan has no root`);
		exit(1);
	}
	const seen = new HashSet<string>();
	const order: string[] = [root];
	seen.add(root);
	for (let k = 0; k < order.length; k += 1) {
		for (const line of fns.get(order[k])!.body) {
			let i = 0;
			while (i < line.length) {
				if (!isIdentStart(line.charAt(i)) || (i > 0 && isIdentChar(line.charAt(i - 1)))) { i += 1; continue; }
				const id = identAt(line, i);
				i += id.length;
				if (!seen.has(id) && fns.has(id)) { seen.add(id); order.push(id); }
			}
		}
	}
	return order;
}

function declaredCells(lines: string[]): HashMap<string, string> {
	const cells = new HashMap<string, string>();
	for (const line of lines) {
		for (const prefix of CELL_TYPES) {
			let from = 0;
			while (true) {
				const at = line.indexOf(prefix, from);
				if (at < 0) break;
				from = at + prefix.length;
				if (at > 0 && isIdentChar(line.charAt(at - 1))) continue;
				let i = skipSpaces(line, at + identAt(line, at).length);
				if (i >= line.length || line.charAt(i) != "*") continue;
				i = skipSpaces(line, i + 1);
				const v = identAt(line, i);
				if (v == "") continue;
				const after = skipSpaces(line, i + v.length);
				const next = after < line.length ? line.charAt(after) : "";
				if ((next == "=" || next == ";" || next == "," || next == ")" || next == "[") && !cells.has(v)) cells.set(v, prefix.slice(0, prefix.length - 2));
			}
		}
	}
	return cells;
}

function opArgument(line: string, at: int32): string {
	const close = line.lastIndexOf(");");
	if (close < at) return "";
	let a = line.slice(at, close).trim();
	while (a.startsWith("(")) {
		const shut = a.indexOf(")");
		const inner = a.slice(1, shut);
		if (shut > 0 && inner.endsWith("*")) a = a.slice(shut + 1).trim();
		else if (a.endsWith(")")) a = a.slice(1, a.length - 1).trim();
		else break;
	}
	return a;
}

function sourceLine(fn: CFunction, index: int32): string {
	for (let k = index; k >= 0; k -= 1) {
		const l = fn.body[k];
		if (l.startsWith("#line ")) {
			const parts = l.slice(6).split(" ");
			if (parts.length >= 2) return `${parts[1].replaceAll("\"", "")}:${parts[0]}`;
		}
	}
	return `${fn.file}:${fn.line + index + 1}`;
}

export function rcOpsOnCells(dir: string): RcOp[] {
	const fns = new HashMap<string, CFunction>();
	collectFunctions(dir, fns);
	const found: RcOp[] = [];
	for (const name of reachedFromEmitJob(fns)) {
		const fn = fns.get(name)!;
		const cells = declaredCells([fn.params].concat(fn.body));
		for (let k = 0; k < fn.body.length; k += 1) {
			const line = fn.body[k];
			for (const op of RC_OPS) {
				const at = line.indexOf(op);
				if (at < 0 || (at > 0 && isIdentChar(line.charAt(at - 1)))) continue;
				const arg = opArgument(line, at + op.length);
				const cell = cells.get(arg);
				if (cell != null) found.push({ fn: name, cell, at: sourceLine(fn, k), text: line.trim() });
				break;
			}
		}
	}
	return found;
}

function emitSelfHost(compiler: string): string {
	const work = `${cwd()}/out/emitRcScan`;
	removeAll(work);
	ensureDir(work);
	const r = execFileCapture(compiler, ["build", `${cwd()}/src/index.ms`, "--emit=c"].concat(argv.filter((a: string): boolean => a.startsWith("--cc="))), work);
	if (!r.ok) {
		console.log(`FAIL self-host: emit for the rc scan failed: ${r.error.message}\n${r.error.errorOutput.slice(r.error.errorOutput.length > 4000 ? r.error.errorOutput.length - 4000 : 0)}`);
		exit(1);
	}
	return `${work}/out/debug`;
}

const params = argv.slice(1).filter((a: string): boolean => !a.startsWith("--"));
if (params.length == 0) {
	console.log("usage: msc run src/test/emitRcScan.ms <candidate msc> [<emitted C dir>]");
	exit(2);
}
const dir = params.length > 1 ? params[1] : emitSelfHost(params[0]);
if (!exists(dir)) {
	console.log(`FAIL self-host: no emitted C at ${dir}`);
	exit(1);
}
const ops = rcOpsOnCells(dir);
for (const op of ops) {
	const at = op.at.startsWith(`${cwd()}/`) ? op.at.slice(cwd().length + 1) : op.at;
	console.log(`FAIL self-host: emit-reached rc op on a ${op.cell} in ${op.fn} at ${at}\n  ${op.text}`);
}
if (ops.length > 0) exit(1);
console.log("emit rc scan: 0 rc ops on Type or Symbol in emit-reached code");
