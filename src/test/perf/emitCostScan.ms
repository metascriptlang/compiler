// Counts the runtime work the compiler emitted per MetaScript function, and ranks what changed between two emits.
//   msc run src/test/perf/emitCostScan.ms <dir>              rows `emit<TAB>fn@module<TAB>metric<TAB>value`
//   msc run src/test/perf/emitCostScan.ms --diff <dirA> <dirB>   top 40 by |delta| of increfs, then lines
//   msc run src/test/perf/emitCostScan.ms --fixtures            rows and diff of src/test/perf/scanFixtures, byte for byte
// incref/increfCyclic exclude pins: an incref whose operand is a `dollarborrow` temp is a borrowPin, so the three sum
// to every incref. decrefCyclic includes msDecrefCyclicEdge. A C name that is no module function keeps its C name and
// module `?unmapped`.
import { argv, cwd, exit } from "std/process";
import { exists, readDir, readFile } from "std/fs";
import { CProgram, collect, isIdentChar } from "../cScan";

const METRICS = ["incref", "decref", "increfCyclic", "decrefCyclic", "borrowPin", "finally", "atomic", "lines"];
const INCREF = 0;
const DECREF = 1;
const INCREF_CYCLIC = 2;
const DECREF_CYCLIC = 3;
const BORROW_PIN = 4;
const FINALLY = 5;
const ATOMIC = 6;
const LINES = 7;
const RC_OPS = ["msIncrefCyclic(", "msDecrefCyclicEdge(", "msDecrefCyclic(", "msIncref(", "msDecref("];
const RC_SLOTS = [INCREF_CYCLIC, DECREF_CYCLIC, DECREF_CYCLIC, INCREF, DECREF];
const ATOMIC_PREFIXES = ["__atomic_", "atomic_", "msAtomic"];
const MODULE_EXTENSIONS = ["Ocms", "Oms", "Ots", "Ojs"];
const UNMAPPED = "?unmapped";
const TOP = 40;
const FIXTURES = "src/test/perf/scanFixtures";

class FnCost {
	key: string;
	module: string;
	counts: int32[] = [0, 0, 0, 0, 0, 0, 0, 0];
}

class Mangled {
	fn: string;
	module: string;
}

function upperOf(two: string): string {
	const n = (two.byteAt(0) - 48) * 10 + (two.byteAt(1) - 48);
	return n >= 65 && n <= 90 ? "ABCDEFGHIJKLMNOPQRSTUVWXYZ".charAt(n - 65) : "";
}

function allDigits(s: string): boolean {
	for (let i = 0; i < s.length; i += 1) {
		if (s.charAt(i) < "0" || s.charAt(i) > "9") return false;
	}
	return s.length > 0;
}

function isModuleToken(m: string): boolean {
	for (let i = m.startsWith("S") || m.startsWith("P") ? 1 : 0; i < m.length; i += 1) {
		const c = m.charAt(i);
		if (!((c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "Z" || c == "O")) return false;
	}
	return true;
}

// Inverse of the module-path mangling in src/codegen/c/names.ms: a-z0-9 stay, Z is `/`, O is `.`, any other
// character is its two-digit code. A two-digit run that is no code stays digits.
function demangleModule(m: string): string {
	let i = 0;
	let out = "";
	if (m.startsWith("P")) { out = "pkg:"; i = 1; } else if (m.startsWith("S")) i = 1;
	while (i < m.length) {
		const c = m.charAt(i);
		const two = i + 1 < m.length ? m.slice(i, i + 2) : "";
		if (c == "Z") { out += "/"; i += 1; }
		else if (c == "O") { out += "."; i += 1; }
		else if (c >= "0" && c <= "9" && two != "") {
			const code = two == "95" ? "_" : two == "45" ? "-" : two == "32" ? " " : two == "63" ? "?" : upperOf(two);
			if (code == "") { out += c; i += 1; } else { out += code; i += 2; }
		} else { out += c; i += 1; }
	}
	return out;
}

// `<name>__<module>_u<N>`, `<Type>__<module>Destroy`, `<Type>__<module>_v<N>Trace`, `<Type>__<module>_init`, `<module>__Init000`.
function demangle(cname: string): Mangled {
	let at = cname.lastIndexOf("__");
	while (at >= 0) {
		const rest = cname.slice(at + 2);
		for (const ext of MODULE_EXTENSIONS) {
			const e = rest.lastIndexOf(ext);
			if (e < 0) continue;
			const tail = rest.slice(e + ext.length);
			const head = cname.slice(0, at);
			if (head.length == 0 || e == 0 || !isModuleToken(rest.slice(0, e + ext.length))) continue;
			const module = demangleModule(rest.slice(0, e + ext.length));
			if (tail.startsWith("_u")) {
				const id = tail.slice(2);
				if (allDigits(id)) return { fn: id == "0" ? head : `${head}#u${id}`, module };
			} else if (tail.startsWith("_v")) {
				let d = 2;
				while (d < tail.length && tail.charAt(d) >= "0" && tail.charAt(d) <= "9") d += 1;
				return { fn: `${head}.${tail.slice(d)}#v${tail.slice(2, d)}`, module };
			} else if (tail.length > 1 && tail.charAt(0) == "_" && tail.charAt(1) >= "a" && tail.charAt(1) <= "z") {
				return { fn: `${head}.${tail.slice(1)}`, module };
			} else if (tail.length > 0 && tail.charAt(0) >= "A" && tail.charAt(0) <= "Z") {
				return { fn: `${head}.${tail}`, module };
			}
		}
		at = at == 0 ? -1 : cname.lastIndexOf("__", at - 1);
	}
	for (const ext of MODULE_EXTENSIONS) {
		const e = cname.indexOf(`${ext}__`);
		if (e > 0 && cname.slice(0, e + ext.length).indexOf("_") < 0) return { fn: cname.slice(e + ext.length + 2), module: demangleModule(cname.slice(0, e + ext.length)) };
	}
	return { fn: cname, module: UNMAPPED };
}

function operandIsBorrowPin(line: string, open: int32): boolean {
	let s = line.slice(open).trim();
	while (s.startsWith("(")) {
		const shut = s.indexOf(")");
		if (shut < 0) break;
		s = s.slice(shut + 1).trim();
	}
	return s.startsWith("dollarborrow");
}

function countLine(raw: string, counts: int32[]): void {
	const line = raw.trim();
	if (line.startsWith("#line ")) return;
	counts[LINES] += 1;
	if (line.startsWith("__finally_") && line.includes(":") && !line.includes("(")) counts[FINALLY] += 1;
	for (let k = 0; k < RC_OPS.length; k += 1) {
		let at = line.indexOf(RC_OPS[k]);
		while (at >= 0) {
			if (at == 0 || !isIdentChar(line.charAt(at - 1))) {
				const slot = RC_SLOTS[k];
				const pin = (slot == INCREF || slot == INCREF_CYCLIC) && operandIsBorrowPin(line, at + RC_OPS[k].length);
				counts[pin ? BORROW_PIN : slot] += 1;
			}
			at = line.indexOf(RC_OPS[k], at + RC_OPS[k].length);
		}
	}
	for (const prefix of ATOMIC_PREFIXES) {
		let at = line.indexOf(prefix);
		while (at >= 0) {
			if (at == 0 || !isIdentChar(line.charAt(at - 1))) counts[ATOMIC] += 1;
			at = line.indexOf(prefix, at + prefix.length);
		}
	}
}

function cFiles(dir: string): string[] {
	return readDir(dir).filter((n: string): boolean => n.endsWith(".c"));
}

function scan(dir: string): HashMap<string, FnCost> {
	const p = new CProgram();
	collect(dir, p);
	const costs = new HashMap<string, FnCost>();
	for (const fn of p.fns.values()) {
		const m = demangle(fn.name);
		const key = `${m.fn}@${m.module}`;
		let cost = costs.get(key);
		if (cost == null) {
			cost = new FnCost();
			cost.key = key;
			cost.module = m.module;
			costs.set(key, cost);
		}
		for (const line of fn.body) countLine(line, cost.counts);
	}
	return costs;
}

function rowsOf(costs: HashMap<string, FnCost>): string[] {
	const keys: string[] = [];
	for (const k of costs.keys()) keys.push(k);
	keys.sort();
	const rows: string[] = [];
	for (const key of keys) {
		const c = costs.get(key)!;
		for (let m = 0; m < METRICS.length; m += 1) rows.push(`emit\t${key}\t${METRICS[m]}\t${c.counts[m]}`);
	}
	return rows;
}

function increfs(c: FnCost | null): int32 {
	return c == null ? 0 : c.counts[INCREF] + c.counts[INCREF_CYCLIC] + c.counts[BORROW_PIN];
}

function linesOf(c: FnCost | null): int32 {
	return c == null ? 0 : c.counts[LINES];
}

function magnitude(n: int32): int32 {
	return n < 0 ? -n : n;
}

function signed(n: int32): string {
	return n > 0 ? `+${n}` : `${n}`;
}

function diffRows(a: HashMap<string, FnCost>, b: HashMap<string, FnCost>): string[] {
	const seen = new HashSet<string>();
	const ranked: string[] = [];
	for (const k of a.keys()) { seen.add(k); ranked.push(k); }
	for (const k of b.keys()) {
		if (!seen.has(k)) ranked.push(k);
	}
	ranked.sort((x: string, y: string): number => {
		const dx = magnitude(increfs(b.get(x) ?? null) - increfs(a.get(x) ?? null));
		const dy = magnitude(increfs(b.get(y) ?? null) - increfs(a.get(y) ?? null));
		if (dx != dy) return dy - dx;
		const lx = magnitude(linesOf(b.get(x) ?? null) - linesOf(a.get(x) ?? null));
		const ly = magnitude(linesOf(b.get(y) ?? null) - linesOf(a.get(y) ?? null));
		if (lx != ly) return ly - lx;
		return x < y ? -1 : x > y ? 1 : 0;
	});
	const rows: string[] = ["function\tmodule\tincref+cyclic+pin A\tB\tdelta\tlines A\tB\tdelta"];
	for (let i = 0; i < ranked.length && i < TOP; i += 1) {
		const key = ranked[i];
		const ca = a.get(key) ?? null;
		const cb = b.get(key) ?? null;
		const cut = key.lastIndexOf("@");
		const ia = increfs(ca);
		const ib = increfs(cb);
		if (ia == ib && linesOf(ca) == linesOf(cb)) break;
		rows.push(`${key.slice(0, cut)}\t${key.slice(cut + 1)}\t${ia}\t${ib}\t${signed(ib - ia)}\t${linesOf(ca)}\t${linesOf(cb)}\t${signed(linesOf(cb) - linesOf(ca))}`);
	}
	for (let m = 0; m < METRICS.length; m += 1) {
		let ta = 0;
		let tb = 0;
		for (const c of a.values()) ta += c.counts[m];
		for (const c of b.values()) tb += c.counts[m];
		rows.push(`total\t${METRICS[m]}\t${ta}\t${tb}\t${signed(tb - ta)}`);
	}
	return rows;
}

function needDir(dir: string): void {
	if (!exists(dir) || cFiles(dir).length == 0) {
		console.log(`FAIL emitCostScan: no .c files in ${dir}`);
		exit(1);
	}
}

function readExpected(name: string): string {
	const r = readFile(`${cwd()}/${FIXTURES}/${name}`);
	if (!r.ok) {
		console.log(`FAIL emitCostScan: cannot read ${FIXTURES}/${name}`);
		exit(1);
	}
	return r.value;
}

function expectEqual(name: string, rows: string[]): void {
	const want = readExpected(name);
	const got = rows.join("\n") + "\n";
	if (got != want) {
		console.log(`FAIL emitCostScan: ${FIXTURES}/${name} differs from the scan:\n${got}`);
		exit(1);
	}
}

function check(): void {
	const a = scan(`${cwd()}/${FIXTURES}/a`);
	const b = scan(`${cwd()}/${FIXTURES}/b`);
	expectEqual("a.rows", rowsOf(a));
	expectEqual("b.rows", rowsOf(b));
	expectEqual("diff.txt", diffRows(a, b));
	console.log("emit cost scan: fixtures match their pinned rows and diff");
}

const args = argv.slice(1).filter((a: string): boolean => a != "--");
if (args.length == 1 && args[0] == "--fixtures") check();
else if (args.length == 3 && args[0] == "--diff") {
	needDir(args[1]);
	needDir(args[2]);
	for (const row of diffRows(scan(args[1]), scan(args[2]))) console.log(row);
} else if (args.length == 1 && !args[0].startsWith("--")) {
	needDir(args[0]);
	for (const row of rowsOf(scan(args[0]))) console.log(row);
} else {
	console.log("usage: msc run src/test/perf/emitCostScan.ms <dir> | --diff <dirA> <dirB> | --fixtures");
	exit(2);
}
