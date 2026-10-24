// Emit workers read the checked program at once, so the code an emit job reaches takes no rc op on
// a cell of that program: not on the cell itself, not by releasing a struct whose destroy hook
// releases one, and not through a void* helper (V5).
import { argv, cwd, execFileCapture, exit } from "std/process";
import { ensureDir, exists, readDir, readFile, removeAll } from "std/fs";

const ROOT_PREFIX = "emitModuleJob__";
const ROOT_SUFFIX = "compileOms_u0";
const RC_OPS = ["msIncrefCyclic(", "msDecrefCyclic(", "msIncref(", "msDecref("];
const PROGRAM_CELLS = ["Node__", "Type__", "Symbol__", "CheckerContext__"];
const JOB_INPUTS = ["ModuleEmissionJob__", "AliveSet__", "CEmissionFacts__"];
const NOT_TYPES = ["return", "goto", "else", "case", "const", "struct", "sizeof"];

interface CFunction {
	name: string;
	file: string;
	line: int32;
	params: string;
	body: string[];
}

interface CDecl {
	type: string;
	name: string;
}

interface RcOp {
	fn: string;
	cell: string;
	at: string;
	text: string;
}

class CProgram {
	fns: HashMap<string, CFunction> = new HashMap<string, CFunction>();
	// struct -> its pointer fields -> their types; a struct held by value is a copy, never another thread's cell
	structs: HashMap<string, HashMap<string, string>> = new HashMap<string, HashMap<string, string>>();
	shared: HashSet<string> = new HashSet<string>();
	releases: HashMap<string, boolean> = new HashMap<string, boolean>();
	erased: HashMap<string, int32[]> = new HashMap<string, int32[]>();
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

function hasPrefix(name: string, prefixes: string[]): boolean {
	for (const p of prefixes) {
		if (name.startsWith(p)) return true;
	}
	return false;
}

// `T* v`, `T v` or `const T* v` at the start of a trimmed fragment, followed by `=`, `;`, `,`, `)`, `[` or its end.
function declOf(text: string): CDecl | null {
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

function definedStruct(line: string): string {
	let s = line.trimEnd();
	if (s.startsWith("typedef ")) s = s.slice(8);
	if (!s.startsWith("struct ") || !s.endsWith("{") || s.includes(";")) return "";
	return identAt(s, skipSpaces(s, 7));
}

function collect(dir: string, into: CProgram): void {
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

// The program's cells, and every declared struct reachable through the fields of the job's inputs. A generic
// instance (`HashSet_<hash>__string`) shares its C type with worker-made ones, so it is judged by its destroy hook.
function markShared(p: CProgram): void {
	const queue: string[] = [];
	for (const st of p.structs.keys()) {
		if (hasPrefix(st, JOB_INPUTS) || hasPrefix(st, PROGRAM_CELLS)) { p.shared.add(st); queue.push(st); }
	}
	for (let k = 0; k < queue.length; k += 1) {
		for (const t of p.structs.get(queue[k])!.values()) {
			if (p.structs.has(t) && !isInstance(t) && !p.shared.has(t)) { p.shared.add(t); queue.push(t); }
		}
	}
}

function isInstance(type: string): boolean {
	const cut = type.indexOf("__");
	return (cut < 0 ? type : type.slice(0, cut)).includes("_");
}

function isShared(p: CProgram, type: string): boolean {
	return p.shared.has(type) || hasPrefix(type, PROGRAM_CELLS);
}

function localTypes(fn: CFunction): HashMap<string, string> {
	const types = new HashMap<string, string>();
	for (const part of fn.params.split(",")) {
		const d = declOf(part);
		if (d != null) types.set(d.name, d.type);
	}
	for (const line of fn.body) {
		const d = declOf(line);
		if (d != null && !types.has(d.name)) types.set(d.name, d.type);
	}
	return types;
}

function stripCasts(arg: string): string {
	let a = arg.trim();
	while (a.startsWith("(")) {
		const shut = a.indexOf(")");
		const inner = a.slice(1, shut);
		if (shut > 0 && inner.endsWith("*")) a = a.slice(shut + 1).trim();
		else if (a.endsWith(")")) a = a.slice(1, a.length - 1).trim();
		else break;
	}
	return a;
}

// The type of `v`, `(*v).f`, `v->f` or `v.f`; "" when the operand has another shape. A field read off a program
// cell is that cell's storage, so it reports the cell's type.
function typeOf(p: CProgram, types: HashMap<string, string>, arg: string): string {
	const a = stripCasts(arg);
	if (a.length > 0 && identAt(a, 0).length == a.length) return types.get(a) ?? "";
	let base = "";
	let field = "";
	if (a.startsWith("(*") && a.includes(").")) {
		base = a.slice(2, a.indexOf(").")).trim();
		field = a.slice(a.indexOf(").") + 2).trim();
	} else if (a.includes("->")) {
		base = a.slice(0, a.indexOf("->")).trim();
		field = a.slice(a.indexOf("->") + 2).trim();
	} else if (a.includes(".")) {
		base = a.slice(0, a.indexOf(".")).trim();
		field = a.slice(a.indexOf(".") + 1).trim();
	}
	if (base == "" || identAt(base, 0).length != base.length || identAt(field, 0).length != field.length) return "";
	const baseType = types.get(base) ?? "";
	const fields = p.structs.get(baseType);
	const fieldType = fields != null ? fields.get(field) ?? "" : "";
	return fieldType != "" && p.structs.has(fieldType) && isShared(p, baseType) ? baseType : fieldType;
}

function rcOpArgument(line: string): string | null {
	for (const op of RC_OPS) {
		const at = line.indexOf(op);
		if (at < 0 || (at > 0 && isIdentChar(line.charAt(at - 1)))) continue;
		const close = line.lastIndexOf(");");
		return close < at + op.length ? "" : line.slice(at + op.length, close);
	}
	return null;
}

// A struct releases a program cell when its destroy hook takes an rc op on one, or on a struct that does.
function releasesShared(p: CProgram, type: string): boolean {
	if (isShared(p, type)) return true;
	const known = p.releases.get(type);
	if (known != null) return known;
	p.releases.set(type, false);
	const hook = p.fns.get(`${type}Destroy`);
	let result = false;
	if (hook != null) {
		const types = localTypes(hook);
		for (const line of hook.body) {
			const arg = rcOpArgument(line);
			if (arg != null && releasesShared(p, typeOf(p, types, arg))) { result = true; break; }
			const call = line.indexOf("Destroy(");
			if (call > 0) {
				let start = call;
				while (start > 0 && isIdentChar(line.charAt(start - 1))) start -= 1;
				const callee = line.slice(start, call);
				if (callee != type && p.structs.has(callee) && releasesShared(p, callee)) { result = true; break; }
			}
		}
	}
	p.releases.set(type, result);
	return result;
}

// Parameters a function takes as void* and passes to an rc op unchanged.
function markErased(p: CProgram): void {
	for (const fn of p.fns.values()) {
		const parts = fn.params.split(",");
		const at: int32[] = [];
		for (let k = 0; k < parts.length; k += 1) {
			const d = declOf(parts[k]);
			if (d == null || d.type != "void" || !parts[k].includes("*")) continue;
			for (const line of fn.body) {
				const arg = rcOpArgument(line);
				if (arg != null && stripCasts(arg) == d.name) { at.push(k); break; }
			}
		}
		if (at.length > 0) p.erased.set(fn.name, at);
	}
}

function callArguments(line: string, open: int32): string[] {
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

function cellKind(p: CProgram, type: string): string {
	const name = type.includes("__") ? type.slice(0, type.indexOf("__")) : type;
	if (isShared(p, type)) return name;
	return releasesShared(p, type) ? `${name} (its destroy hook releases a program cell)` : "";
}

export function rcOpsOnCells(dir: string): RcOp[] {
	const p = new CProgram();
	collect(dir, p);
	markShared(p);
	markErased(p);
	const found: RcOp[] = [];
	for (const name of reachedFromEmitJob(p.fns)) {
		const fn = p.fns.get(name)!;
		const types = localTypes(fn);
		for (let k = 0; k < fn.body.length; k += 1) {
			const line = fn.body[k];
			const arg = rcOpArgument(line);
			if (arg != null) {
				const kind = cellKind(p, typeOf(p, types, arg));
				if (kind != "") found.push({ fn: name, cell: kind, at: sourceLine(fn, k), text: line.trim() });
				continue;
			}
			for (const callee of p.erased.keys()) {
				const open = line.indexOf(`${callee}(`);
				if (open < 0 || (open > 0 && isIdentChar(line.charAt(open - 1)))) continue;
				const args = callArguments(line, open + callee.length);
				for (const at of p.erased.get(callee)!) {
					const kind = at < args.length ? cellKind(p, typeOf(p, types, args[at])) : "";
					if (kind != "") found.push({ fn: name, cell: `${kind} through the void* helper ${callee}`, at: sourceLine(fn, k), text: line.trim() });
				}
			}
		}
	}
	return found;
}

// Each fixture directory named red-* must be refused and each green-* accepted, so a shape the scan stops seeing fails here.
function checkFixtures(root: string): void {
	let count = 0;
	for (const name of readDir(root)) {
		const red = name.startsWith("red-");
		if (!red && !name.startsWith("green-")) continue;
		count += 1;
		const ops = rcOpsOnCells(`${root}/${name}`);
		if (red != (ops.length > 0)) {
			console.log(`FAIL self-host: rc scan fixture ${name} expected ${red ? "a finding" : "none"}, found ${ops.length}`);
			exit(1);
		}
	}
	if (count == 0) {
		console.log(`FAIL self-host: no rc scan fixtures under ${root}`);
		exit(1);
	}
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
checkFixtures(`${cwd()}/src/test/emitRcScanFixtures`);
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
console.log("emit rc scan: 0 rc ops on the checked program in emit-reached code");
