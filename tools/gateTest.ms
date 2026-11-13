import { argv, cwd, execFileCapture, exit } from "std/process";
import { ensureDir, exists, removeAll, writeFile } from "std/fs";

interface CaseResult {
	name: string;
	expected: string;
	actual: string;
}

const params = argv.slice(1).filter((a: string): boolean => !a.startsWith("--"));
const compiler = params.length > 0 && params[0].startsWith("/") ? params[0] : `${cwd()}/${params.length > 0 ? params[0] : "msc"}`;

function makeRoot(): string {
	let n = performance.now() as int64;
	while (exists(`/tmp/msc-gate-verdict-${n}`)) n = n + 1;
	ensureDir(`/tmp/msc-gate-verdict-${n}`);
	return `/tmp/msc-gate-verdict-${n}`;
}

const root = makeRoot();
const results: CaseResult[] = [];
const tool = `${root}/gate`;
const built = execFileCapture(compiler, ["build", "tools/gate.ms", `--output=${tool}`], cwd());
if (!built.ok) {
	console.log(`FAIL  tools/gate.ms builds  expected=built actual=${(built.error.output + built.error.errorOutput).trim()}`);
	exit(1);
}

function put(path: string, content: string): void {
	if (writeFile(path, content).ok) return;
	console.log(`gate verdict: cannot write ${path}`);
	exit(1);
}

function log(body: string[], rc: number, secs: number = 3): string {
	return body.concat(["", `SECS=${secs}`, `RC=${rc}`, "END", ""]).join("\n");
}

let cases = 0;
function verdict(known: string, logs: string[][], hostKnown: string = "{}", files: string[][] = []): string {
	cases = cases + 1;
	const dir = `${root}/case${cases}`;
	ensureDir(dir);
	put(`${dir}.json`, known);
	put(`${dir}.host.json`, hostKnown);
	for (const pair of logs) put(`${dir}/${pair[0]}.log`, pair[1]);
	for (const pair of files) put(`${dir}/${pair[0]}`, pair[1]);
	const r = execFileCapture(tool, [dir, `${dir}.json`, `${dir}.host.json`], cwd());
	const out = r.ok ? r.value : `${r.error.output}${r.error.errorOutput}exit ${r.error.exitCode}`;
	return out.trim().split("\n").map((l: string): string => l.trim()).join("|");
}

function record(name: string, expected: string, actual: string): void {
	results.push({ name, expected, actual });
}

function news(out: string): string {
	return out.split("|").filter((l: string): boolean => l.startsWith("new: ")).map((l: string): string => l.substring(5)).join("|");
}

record("each lane names its reds the way its runner prints them",
	[
		"setup: build the fixture", "wrongKey",
		"self-host: builder changed during gen1", "self-host: gen2 differs from gen3",
		"711-http [c]", "js src/test/crypto/ecApiVectors.ms", "src/a.ms",
		"hookOrder", "std/solana/test.ms", "src/test/c/index.ms > no result", "src/x.ms > adds", "tools/wt.sh",
	].join("|"),
	news(verdict("{}", [
		["boundary", log(["FAIL  wrongKey  expected=a actual=b", "boundary: setup step failed: build the fixture (root /tmp/x)"], 1)],
		["build", log(["FAIL self-host: gen2 differs from gen3 (see out/x)", "FAIL self-host: builder changed during gen1"], 1)],
		["corpus", log(["  ✗ FAIL 711-http [c] exit 1", "note: ✗ FAIL quoted [c]"], 1)],
		["crypto", log(["ok   c src/test/crypto/hashApiVectors.ms 5/5 2s", "RED  js src/test/crypto/ecApiVectors.ms 3/4 exit 1 9s"], 1)],
		["fmt", log(["LOSSY src/a.ms drops a comment"], 1)],
		["guard", log(["\x1b[31mFAIL hookOrder: the ledger differs\x1b[0m"], 1)],
		["solana", log(["FAIL solana std/solana/test.ms: exit 1"], 1)],
		["suite", log([` FAIL  ${cwd()}/src/x.ms`, "  × adds", "NORESULT src/test/c/index.ms > no result"], 1)],
		["tools", log(["FAIL tools/wt.sh: bash -n", "FAIL tools/y.ms: run"], 1)],
	])));

record("a failed part that names nothing is a red of its own",
	"build|crypto setup|guard.1: exit 2 with no named failure|timed out|lsp: the log has no RC and SECS trailer",
	news(verdict("{}", [
		["build", log(["nothing named"], 2)],
		["crypto", log(["nothing named"], 2)],
		["guard.0", log(["ok"], 0)],
		["guard.1", log(["nothing named"], 2)],
		["hcr", log(["TIMEOUT after 600s"], 124)],
		["lsp", "ok\n"],
	])));

record("the parts of a lane give one line with the slowest part's seconds, and green exits 0",
	"gate: guard 9s · 0 red · 0 known · 0 new|gate: GREEN (guard)",
	verdict("{}", [["guard.0", log(["ok a"], 0, 4)], ["guard.1", log(["ok b"], 0, 9)]]));

const rows = "{\"fmt\":{\"a.ms\":{},\"b.ms\":{},\"c.ms\":{}},\"corpus\":{},\"flaky\":{\"c.ms\":{},\"405-counter\":{}}}";
record("a known red is not new, a green known row is named, a flaky id is neither",
	"gate: corpus 3s · 0 red · 0 known · 0 new · 1 flaky (405-counter [c])|gate: fmt 3s · 1 red · 1 known · 0 new · 1 known-now-green (a.ms) · 1 flaky (c.ms)|known-now-green: a.ms|gate: GREEN (corpus, fmt)",
	verdict(rows, [["corpus", log(["✗ FAIL 405-counter [c] hung"], 1)], ["fmt", log(["LOSSY b.ms x", "UNSTABLE c.ms y"], 1)]]));

record("a new red beside a known one fails the gate",
	"gate: fmt 3s · 2 red · 1 known · 1 new · 1 known-now-green (a.ms)|new: e.ms|known-now-green: a.ms|gate: RED (fmt)|exit 1",
	verdict(rows, [["fmt", log(["LOSSY b.ms x", "NO-FMT e.ms"], 1)]]));

record("a second known file adds its rows",
	"gate: fmt 3s · 2 red · 2 known · 0 new · 1 known-now-green (a.ms)|known-now-green: a.ms|gate: GREEN (fmt)",
	verdict(rows, [["fmt", log(["LOSSY b.ms x", "NO-FMT e.ms"], 1)]], "{\"fmt\":{\"e.ms\":{}}}"));

const rerun = log(["  ✗ FAIL onMain [c] exit 1", "  ✗ FAIL once [c] exit 1", "  ✗ FAIL twice [c] exit 1", "  ✗ FAIL never [c] exit 1"], 1);
record("a new red that main shows, or that this candidate shows fewer than twice of three, is not the slice's",
	"gate: corpus 3s · 4 red · 0 known · 1 new · 3 not the slice's|new: twice [c]|not the slice's: never [c] (red 0/3 on this candidate, 0/3 on main)|not the slice's: onMain [c] (red on main 1/3)|not the slice's: once [c] (red 1/3 on this candidate, 0/3 on main)|gate: RED (corpus)|exit 1",
	verdict("{}", [["corpus", rerun]], "{}", [
		["changed.paths", "src/checker/checkPass.ms\n"],
		["corpus.reruns.main", "onMain [c]\n"],
		["corpus.reruns.slice", "once [c]\ntwice [c]\ntwice [c]\nonMain [c]\n"],
	]));

record("reds that are all not the slice's leave the gate green",
	"gate: guard 3s · 1 red · 0 known · 0 new · 1 not the slice's|not the slice's: hookOrder (red on main 3/3)|gate: GREEN (guard)",
	verdict("{}", [["guard", log(["FAIL hookOrder: the ledger differs"], 1)]], "{}", [
		["changed.paths", ""],
		["guard.reruns.main", "hookOrder\nhookOrder\nhookOrder\n"],
		["guard.reruns.slice", "hookOrder\nhookOrder\nhookOrder\n"],
	]));

record("a rerun does not judge a test the slice edits, a missing result or a timeout",
	"src/test/c/index.ms > no result|src/test/c/json.ms > parses numbers|timed out",
	news(verdict("{}", [["tests", log([` FAIL  ${cwd()}/src/test/c/json.ms`, "  × parses numbers", "NORESULT src/test/c/index.ms > no result", "TIMEOUT after 600s"], 1)]], "{}", [
		["changed.paths", "src/test/c/json.ms\n"],
		["tests.reruns.main", "src/test/c/json.ms > parses numbers\nsrc/test/c/index.ms > no result\ntimed out\n"],
		["tests.reruns.slice", ""],
	])));

record("reruns with no list of the slice's changed paths are refused",
	"true",
	`${verdict("{}", [["hcr", log(["FAIL hcrRun: exit 1"], 1)]], "{}", [["hcr.reruns.main", ""], ["hcr.reruns.slice", ""]]).includes("hcr has reruns and")}`);

let failures = 0;
console.log(`root ${root}`);
for (const r of results) {
	const pass = r.expected == r.actual;
	if (!pass) failures = failures + 1;
	console.log(`${pass ? "pass" : "FAIL"}  ${r.name}  expected=${r.expected} actual=${r.actual}`);
}
if (failures == 0) removeAll(root);
exit(failures == 0 ? 0 : 1);
