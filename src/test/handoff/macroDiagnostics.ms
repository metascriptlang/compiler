import { compileToCWithStd, compileToJSWithStd } from "../helpers";
import { createInterpreter, evalModule, Evaluation, Diagnostic } from "../../embed/index";
import { resolveRuntimeDir } from "../../utils/path";
import { mkdir, ensureDir, readFile, writeFile, remove, removeAll, exists, fileSize, modifiedTime, changeStamp } from "std/fs";
import { join } from "std/fs/path";
import { cwd } from "std/process";

test "macro diagnostics: rejection crosses frames once and cannot be caught" {
	const bodies = [
		'error("rejected input", node);',
		'function reject(n: Node): void { error("rejected input", n); } reject(node);',
		'function reject(n: Node): Node[] { error("rejected input", n); return []; } const values = reject(node);',
		'function reject(n: Node): void { error("rejected input", n); } try { reject(node); } catch (e) {}',
		'function reject(n: Node): void { error("rejected input", n); } function relay(n: Node): void { const spare = [1, 2]; try { reject(n); } catch (e) {} } relay(node);',
	];
	for (const body of bodies) {
		const source = 'import { Node } from "std/meta"; macro requireValid(node: Node): Node { '
			+ body + ' error("continued after rejection", node); return node; } const value = requireValid(1);';
		const result = compileToCWithStd(source);
		assert !result.ok, body;
		assert result.error.split("rejected input").length == 2, result.error;
		assert !result.error.contains("continued after rejection"), result.error;
		assert !result.error.contains("possible recursive macro"), result.error;
	}
}

test "macro diagnostics: error() as a returned value or an operand rejects like the statement form, imported or not" {
	const bodies = [
		'return error("rejected input", node);',
		'return node.line > 0 ? error("rejected input", node) : node;',
		'function reject(n: Node): Node { return error("rejected input", n); } return reject(node);',
		'function reject(n: Node): Node { return error("rejected input", n); } try { return reject(node); } catch (e) { return node; }',
	];
	const imports = ['import { Node } from "std/meta"; ', 'import { Node, error } from "std/meta"; '];
	for (const head of imports) {
		for (const body of bodies) {
			const source = head + 'macro requireValid(node: Node): Node { ' + body + ' } const value = requireValid(1);';
			for (const result of [compileToCWithStd(source), compileToJSWithStd(source)]) {
				assert !result.ok, body;
				assert result.error.split("Macro 'requireValid': rejected input").length == 2, result.error;
			}
		}
	}
}

test "macro diagnostics: a number literal that contradicts itself is refused at the invocation" {
	const header = 'import { Node, NodeKind } from "std/meta"; macro bad(node: Node): Node { ';
	const cases = [
		{ body: 'return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: 3.5, isFloat: false, intVal: 0, outOfRangeText: "", isBitPattern: false };', says: "Macro 'bad': a NumberLiteral declares isFloat: false, and its value 3.5 is not an integer" },
		{ body: 'const n: int64 = 7; return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: 2.5, isFloat: true, intVal: n, outOfRangeText: "", isBitPattern: false };', says: "Macro 'bad': a NumberLiteral declares isFloat: true and intVal 7" },
	];
	for (const c of cases) {
		const result = compileToCWithStd(header + c.body + ' } const value = bad(0);');
		assert !result.ok, c.body;
		assert result.error.contains(c.says), result.error;
	}
}

test "macro diagnostics: nested helper errors and wrapper errors both survive compilation" {
	const cases = [
		{ body: 'function helper(n: Node): string { return "ok"; } macro use(n: Node): Node { const bad = n.missingField; const s = helper(n); return n; }', dependency: "missingField" },
		{ body: 'function helper(n: Node): Node { return missingHelper(n); } macro use(n: Node): Node { return helper(n); }', dependency: "helper" },
	];
	for (const item of cases) {
		const result = compileToCWithStd('import { Node } from "std/meta"; ' + item.body + ' const value = use(1);');
		assert !result.ok, item.body;
		assert result.error.contains(item.dependency), result.error;
	}
	const healthy = compileToCWithStd('import { Node } from "std/meta"; function helper(n: Node): Node { return n; } macro use(n: Node): Node { return helper(n); } const value: int32 = use(42);');
	assert healthy.ok;
}

test "macro diagnostics: ordinary exceptions retain their payload" {
	const result = compileToCWithStd('import { Node } from "std/meta"; macro reject(n: Node): Node { throw new Error("macro exception payload"); return n; } const value = reject(1);');
	assert !result.ok;
	assert result.error.contains("macro exception payload"), result.error;
}

const mutableStateSource = `
import { Node, NodeKind } from "std/meta";

let COUNTER = "ABC";

export macro usesVar(node: Node): Node {
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: COUNTER };
}

function main(): void {
	const x = usesVar(0);
	console.log(x);
}
main();
`;

test "macro unsupported evaluation: mutable module state identifies the unavailable dependency" {
	const c = compileToCWithStd(mutableStateSource);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("COUNTER");
	}
}

const unbridgedCallSource = `
import { Node, NodeKind } from "std/meta";

export macro usesDead(node: Node): Node {
	const t = setTimeout((): void => {}, 0);
	const v = "x";
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = usesDead(0);
	console.log(x);
}
main();
`;

test "macro unsupported evaluation: a timer a macro starts names the module state the VM cannot read" {
	for (const timer of ["setTimeout", "setInterval"]) {
		const c = compileToCWithStd(unbridgedCallSource.replace("setTimeout", timer));
		assert !c.ok;
		if (!c.ok) {
			assert c.error.contains("timerNext"), c.error;
		}
	}
}

test "macro unsupported evaluation: a helper that reads an extern let or const is refused by its name" {
	const helpers = [
		{ decl: "extern let errno: int32;", body: "let err: int32 = 0; err = errno != 0 ? errno : 1; return `${err}`;", name: "errno" },
		{ decl: "extern const MASK: uint32;", body: "const m: uint32 = 5; return `${m & MASK}`;", name: "MASK" },
		{ decl: "extern const BASE: int32;", body: "const b: int32 = BASE + 1; return `${b}`;", name: "BASE" },
		{ decl: "extern const LIMIT: float64;", body: "return 2.5 < LIMIT ? \"lt\" : \"ge\";", name: "LIMIT" },
	];
	for (const h of helpers) {
		const result = compileToCWithStd('import { Node, NodeKind } from "std/meta"; ' + h.decl
			+ " function code(): string { " + h.body + " }"
			+ " macro lib(n: Node): Node { return { kind: NodeKind.StringLiteral, line: n.line, column: n.column, value: code() }; }"
			+ ' console.log(lib("x"));');
		assert !result.ok, h.decl;
		assert result.error.contains(`cannot read extern '${h.name}'`), result.error;
	}
}

const stdFsMacroHead = 'import { Node, NodeKind } from "std/meta"; import { writeFile, appendFile, readFile } from "std/fs"; ';

function stringMacro(body: string): string {
	return stdFsMacroHead + "macro probe(n: Node): Node { " + body + " return { kind: NodeKind.StringLiteral, line: n.line, column: n.column, value: text }; } console.log(probe(0));";
}

test "macro std fs: writeFile and appendFile run at comptime through their host routine and leave their file" {
	const dir = join(cwd(), "out/test");
	mkdir(dir);
	const path = join(dir, "macroStdFsCallback.txt");
	remove(path);
	const result = compileToCWithStd(stringMacro(`const first = writeFile("${path}", "one;"); const second = appendFile("${path}", "two;"); const back = readFile("${path}"); const text = (first.ok && second.ok ? "wrote:" : "failed:") + (back.ok ? back.value : "unread");`));
	assert result.ok, result.ok ? "" : result.error;
	if (result.ok) assert result.value.contains("wrote:one;two;"), result.value;
	const file = readFile(path);
	assert file.ok && file.value == "one;two;";
}

test "macro std fs: a failed writeFile at comptime returns its IoError with path and kind" {
	const result = compileToCWithStd(stringMacro('const r = writeFile("/nonexistent-dir-of-a-macro/f.txt", "x"); const text = r.ok ? "wrote" : `refused:${r.error.path}:${r.error.kind}`;'));
	assert result.ok, result.ok ? "" : result.error;
	if (result.ok) assert result.value.contains("refused:/nonexistent-dir-of-a-macro/f.txt:"), result.value;
}

const stdFsOpsHead = 'import { Node, NodeKind } from "std/meta"; import { IoErrorKind } from "std/io/errors"; '
	+ 'import { ensureDir, mkdir, rmdir, remove, removeAll, rename, writeFile, writeLines, readLines, copyFile, readDir, exists, isDir } from "std/fs"; ';

function fsOpsMacro(base: string): string {
	const dir = `${base}/a/b`;
	return stdFsOpsHead + "macro probe(n: Node): Node { "
		+ `const made = ensureDir("${dir}"); const again = ensureDir("${dir}"); const twice = mkdir("${dir}");`
		+ ` const wrote = writeFile("${dir}/f.txt", "x"); const moved = rename("${dir}/f.txt", "${dir}/g.txt");`
		+ ` const listed = readDir("${dir}").join(","); const there = exists("${dir}/g.txt") && isDir("${dir}");`
		+ ` const removed = remove("${dir}/g.txt"); const gone = !exists("${dir}/g.txt"); const missing = remove("${dir}/g.txt");`
		+ ` const blocked = rmdir("${base}/a"); const cleared = removeAll("${base}/a").ok && !exists("${base}/a");`
		+ ` const copied = writeLines("${base}/l.txt", ["p", "q"]).ok && copyFile("${base}/l.txt", "${base}/m.txt").ok; const lines = readLines("${base}/m.txt");`
		+ ' const linesText = lines.ok ? lines.value.join("+") : "unread";'
		+ " const missed = missing.ok ? \"ok\" : `${missing.error.kind == IoErrorKind.NotFound}|${missing.error.path}|${missing.error.message}`;"
		+ " const text = `made=${made.ok} again=${again.ok} twice=${twice.ok} wrote=${wrote.ok} moved=${moved.ok} listed=${listed} there=${there}"
		+ " removed=${removed.ok} gone=${gone} missing=${missed} blocked=${!blocked.ok} cleared=${cleared} copied=${copied} lines=${linesText}`;"
		+ " return { kind: NodeKind.StringLiteral, line: n.line, column: n.column, value: text }; } console.log(probe(0));";
}

function fsOpsExpected(base: string): string {
	const missingPath = `${base}/a/b/g.txt`;
	const missing = remove(missingPath);
	const message = missing.ok ? "removed a path that should be missing" : missing.error.message;
	return `made=true again=true twice=true wrote=true moved=true listed=g.txt there=true removed=true gone=true missing=true|${missingPath}|${message} blocked=true cleared=true copied=true lines=p+q`;
}

test "macro std fs: ensureDir, mkdir on an existing dir, rename, readDir, remove, rmdir, removeAll, writeLines, copyFile and readLines run at comptime with the runtime's results and errors" {
	const targets = ["c", "js"];
	for (const target of targets) {
		const base = join(cwd(), `out/test/macroStdFsOps-${target}`);
		removeAll(base);
		const result = target == "c" ? compileToCWithStd(fsOpsMacro(base)) : compileToJSWithStd(fsOpsMacro(base));
		assert result.ok, result.ok ? "" : `${target}: ${result.error}`;
		if (result.ok) assert result.value.contains(fsOpsExpected(base)), `${target}: ${result.value}`;
		assert !exists(base + "/a"), target;
	}
}

function statMacro(file: string, missing: string): string {
	return 'import { Node, NodeKind } from "std/meta"; import { fileSize, modifiedTime, changeStamp } from "std/fs"; '
		+ "macro probe(n: Node): Node { "
		+ `const text = \`size=\${fileSize("${file}")} time=\${modifiedTime("${file}")} stamp=\${changeStamp("${file}")}`
		+ ` missing=\${fileSize("${missing}")}|\${modifiedTime("${missing}")}|\${changeStamp("${missing}")}\`;`
		+ " return { kind: NodeKind.StringLiteral, line: n.line, column: n.column, value: text }; } console.log(probe(0));";
}

test "macro std fs: fileSize, modifiedTime and changeStamp run at comptime with the runtime's answers for a file and a missing path" {
	const targets = ["c", "js"];
	for (const target of targets) {
		const base = join(cwd(), `out/test/macroStdFsStat-${target}`);
		removeAll(base);
		mkdir(base);
		const file = `${base}/f.txt`;
		const missing = `${base}/none`;
		writeFile(file, "hello");
		const expected = `size=5 time=${modifiedTime(file)} stamp=${changeStamp(file)} missing=${fileSize(missing)}|${modifiedTime(missing)}|${changeStamp(missing)}`;
		const result = target == "c" ? compileToCWithStd(statMacro(file, missing)) : compileToJSWithStd(statMacro(file, missing));
		assert result.ok, result.ok ? "" : `${target}: ${result.error}`;
		if (result.ok) assert result.value.contains(expected), `${target}: ${expected} in ${result.value}`;
		removeAll(base);
	}
}

function stdCallMacro(imports: string, call: string): string {
	return 'import { Node, NodeKind } from "std/meta"; ' + imports
		+ " macro probe(n: Node): Node { const text = `${" + call + "}`; return { kind: NodeKind.StringLiteral, line: n.line, column: n.column, value: text }; } console.log(probe(0));";
}

function refusalsIn(error: string): int32 {
	return error.split("cannot run on the Raiser").length - 1;
}

test "macro std tiers: a std routine the Raiser cannot run is refused once at the macro's call, naming the routine, its module, the reason and where it runs" {
	const cases = [
		{ imports: 'import { createSocket } from "std/net";', call: "createSocket()", refusal: "'createSocket' from 'std/net' cannot run on the Raiser: no host bridge for 'msNetSocket'; it runs on C" },
		{ imports: 'import { blake2bSync } from "std/crypto/blake2b";', call: 'blake2bSync("abc").ok', refusal: "'blake2bSync' from 'std/crypto/blake2b' cannot run on the Raiser: no host bridge for 'msBlake2b'; it runs on C and JS" },
		{ imports: 'import { cpus } from "std/os";', call: "cpus().length", refusal: "'cpus' from 'std/os' cannot run on the Raiser: no host bridge for 'msOsCpuCount' (and 1 more); it runs on C" },
		{ imports: 'import { randomUUIDSync } from "std/crypto";', call: "randomUUIDSync().ok", refusal: "'randomUUIDSync' from 'std/crypto' cannot run on the Raiser: no host bridge for 'msCryptoRandomUuid'; it runs on C and JS" },
	];
	for (const c of cases) {
		const result = compileToCWithStd(stdCallMacro(c.imports, c.call));
		assert !result.ok, c.call;
		if (!result.ok) {
			assert result.error.contains(c.refusal), result.error;
			assert refusalsIn(result.error) == 1, result.error;
		}
	}
}

test "macro std tiers: an extern with no host bridge called by a macro or a @comptime block is refused by its name" {
	const viaMacro = compileToCWithStd(stdCallMacro("extern function msOsHostname(): string;", "msOsHostname().length"));
	const viaBlock = compileToCWithStd("extern function msOsHostname(): string; const n: number = @comptime { return msOsHostname().length; }; console.log(n);");
	for (const result of [viaMacro, viaBlock]) {
		assert !result.ok;
		if (!result.ok) assert result.error.contains("'msOsHostname' cannot run on the Raiser: no host bridge for 'msOsHostname'"), result.error;
	}
}

test "macro std tiers: a std routine its module's Raiser tier lacks is refused once at the macro's call" {
	const result = compileToCWithStd('import { Node, NodeKind } from "std/meta"; import { utf8String } from "std/core/string/bytes";'
		+ " macro probe(n: Node): Node { const bytes: uint8[] = [104, 105]; const text = utf8String(bytes, false); return { kind: NodeKind.StringLiteral, line: n.line, column: n.column, value: text }; } console.log(probe(0));");
	assert !result.ok;
	if (!result.ok) {
		assert result.error.contains("'utf8String' from 'std/core/string/bytes' cannot run on the Raiser: the Raiser tier of std/core/string/bytes does not declare 'utf8String'; it runs on C"), result.error;
		assert !result.error.contains("cannot evaluate"), result.error;
		assert !result.error.contains("internal:"), result.error;
	}
}

test "macro std tiers: a @comptime block that calls a std routine the Raiser cannot run is refused at the block's call" {
	const result = compileToCWithStd('import { cpus } from "std/os"; const n: number = @comptime { return cpus().length; }; console.log(n);');
	assert !result.ok;
	if (!result.ok) {
		assert result.error.contains("@comptime block: 'cpus' from 'std/os' cannot run on the Raiser: no host bridge for 'msOsCpuCount'"), result.error;
		assert refusalsIn(result.error) == 1, result.error;
	}
}

function raiserRun(source: string): Result<Evaluation, Diagnostic[]> {
	const dir = join(cwd(), `out/test/raiserTiers.${performance.now()}`);
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, source);
	const created = createInterpreter(resolveRuntimeDir());
	if (!created.ok) throw new Error(created.error);
	const r = evalModule(created.value, `${dir}/main.ms`);
	removeAll(dir);
	return r;
}

function refusedAt(source: string, refusal: string, line: int32): string {
	const r = raiserRun(source);
	if (r.ok) return `ran: ${r.value.output}`;
	for (const d of r.error) {
		if (d.message.includes(refusal)) return d.line == line ? "" : `refused at line ${d.line}: ${d.message}`;
	}
	return r.error.map((d: Diagnostic): string => `${d.line}:${d.column} ${d.message}`).join("\n");
}

test "raiser run tiers: an import of a module with no Raiser tier is refused at the import, naming what it imports and where it runs" {
	assert refusedAt('import { blake2bSync } from "std/crypto/blake2b";\nconsole.log(blake2bSync("abc").ok);\n',
		"'blake2bSync' from 'std/crypto/blake2b' cannot run on the Raiser: the module has no Raiser tier; it runs on C and JS", 1) == "";
	assert refusedAt('console.log("first");\nimport { createSocket, listen } from "std/net";\nconsole.log(createSocket() >= 0);\n',
		"'createSocket', 'listen' from 'std/net' cannot run on the Raiser: the module has no Raiser tier; it runs on C", 2) == "";
	assert refusedAt('import { nothing } from "./noSuchModule";\nconsole.log(nothing);\n', "Cannot resolve module './noSuchModule'", 0) == "";
}

test "raiser run tiers: a name a module's Raiser tier lacks is refused at the import, naming where it runs, and a name no tier has keeps its message" {
	assert refusedAt('import { cpus } from "std/os";\nconsole.log(cpus().length > 0);\n',
		"'cpus' from 'std/os' cannot run on the Raiser: its Raiser tier does not declare it; it runs on C", 1) == "";
	assert refusedAt('import { sha256Sync, randomUUIDSync } from "std/crypto";\nconsole.log(randomUUIDSync().ok);\n',
		"'randomUUIDSync' from 'std/crypto' cannot run on the Raiser: its Raiser tier does not declare it; it runs on C and JS", 1) == "";
	assert refusedAt('import { noSuchRoutine } from "std/os";\nconsole.log(noSuchRoutine);\n', "Module 'std/os' has no export 'noSuchRoutine'", 1) == "";
}

test "raiser run tiers: a reached call the Raiser cannot run is a compile error at the call, before the program prints" {
	assert refusedAt('extern function msOsHostname(): string;\nconsole.log("before");\nconsole.log(msOsHostname().length > 0);\n',
		"'msOsHostname' cannot run on the Raiser: no host bridge for 'msOsHostname'", 3) == "";
	assert refusedAt('function one(): int32 {\n\tconst v = await spawn((): int32 => 1, { timeout: 100 });\n\treturn v;\n}\nconsole.log(one());\n',
		"'spawn' from 'std/core/promise' cannot run on the Raiser: no host bridge for 'msSpawn'; it runs on C and JS", 2) == "";
	assert refusedAt('function bump(c: Locked<int32>): void { lockedUpdate(c, (v: int32): int32 => v + 1); }\nconst f = bump;\nconsole.log("before");\n',
		"'lockedUpdate' from 'std/core/promise' cannot run on the Raiser: no host bridge for 'msLockedHeldHere'", 1) == "";
}

test "raiser run tiers: an unbridged extern in a std body or a user function the program never calls still compiles and runs" {
	const r = raiserRun('extern function nowhere(): int32;\nfunction unused(): int32 { return nowhere(); }\nconsole.log("ok");\n');
	assert r.ok, r.ok ? "" : r.error.map((d: Diagnostic): string => d.message).join("\n");
	if (r.ok) {
		assert r.value.output == "ok\n", r.value.output;
		assert r.value.warnings.length == 0, r.value.warnings.map((d: Diagnostic): string => d.message).join("\n");
	}
}

const objectCallMacro = `
import { Node, NodeKind } from "std/meta";

interface S { width: number | null; }

export function idS(s: S): S { return s; }

export macro mk(node: Node): Node {
	return {
		kind: NodeKind.CallExpr, line: node.line, column: node.column,
		callee: { kind: NodeKind.Identifier, line: node.line, column: node.column, name: "idS" },
		arguments: [node],
	};
}

`;

test "macro diagnostics: emitted object calls enforce keys before emission" {
	const cases = [
		{ object: "{ width: 1 }", accepted: true },
		{ object: "{ widht: 1 }", accepted: false },
		{ object: "{ width: 1, width: 2 }", accepted: false },
	];
	for (const item of cases) {
		const result = compileToCWithStd(objectCallMacro + "const value = mk(" + item.object + ");");
		assert result.ok == item.accepted, item.object;
	}
}

test "macro expansion identity: unresolved bound symbols fail before emission" {
	const result = compileToCWithStd('import { Node, NodeKind } from "std/meta"; macro unresolved(n: Node): Node { return { kind: NodeKind.CallExpr, line: n.line, column: n.column, callee: bindSym("absentHelper"), arguments: [n] }; } const value = unresolved(1);');
	assert !result.ok;
	assert result.error.contains("absentHelper"), result.error;
}

test "macro exception operands: only error values and strings enter catch" {
	const refused = [
		"function f(): void { throw 7; }",
		"function f(n: number): void { throw n; }",
		"function f(): void { throw null; }",
		"function f(value: Error | null): void { throw value; }",
		"function f(value: unknown): void { throw value; }",
	];
	for (const source of refused) assert !compileToCWithStd(source).ok, source;
	const accepted = [
		'function f(): void { throw new Error("x"); }',
		'function f(value: Error | null): void { if (value !== null) throw value; }',
		'function f(): void { try { f(); } catch (e) { throw e; } }',
		'function f(): void { throw "x"; }',
		'function f(value: string): void { throw value; }',
		'function f(value: int32): void { throw `value=${value}`; }',
	];
	for (const source of accepted) assert compileToCWithStd(source).ok, source;
}
