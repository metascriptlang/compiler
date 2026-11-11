import { BuildGraph, GraphNode, GraphPath, GraphArg, ArgKind, nodeById, sourcePath } from "./configure";
import { CliOptions } from "../options";
import { hashFile, loadFileHashes, saveFileHashes } from "../cache";
import { hashContent } from "../../utils/contentHash";
import { stepStoreRoot, storedOutput, storeScratch, storePublish } from "./store";
import { atomicCopyFile, atomicWriteFile } from "../io";
import { exists, isDir, readDir, readFile, writeFile, ensureDir, removeAll } from "std/fs";
import { join, dirname, basename, isAbsolute } from "std/fs/path";
import { execPath, platform, findOnPath } from "std/process";
import { spawn, ChildProcess, ChildStream } from "std/process/child";
import { totalMem } from "std/os";
import { writeStdout, writeStderr } from "std/io";
import { vmCallFunction } from "../../raiser/vm";
import { field } from "../../raiser/marshal";

const STORE_FORMAT = "bg1";

export interface Execution {
	graph: BuildGraph;
	opts: CliOptions;
	projectRoot: string;
	outputs: HashMap<int32, string>;
	digests: HashMap<int32, string>;
	dryRun: boolean;
	ran: string[];
	reused: string[];
	passArgs: string[];
	target: int32;
	jobs: int32;
	seed: int32;   // nonzero: start ready nodes in an order shuffled by this seed
	hashed: string[];
	maxRss: number;
	claimedRss: number;
}

function buildMaxRss(opts: CliOptions): number {
	if (opts.graphMaxRss > 0) return opts.graphMaxRss;
	const total = totalMem() as number;
	return total > 0 ? total : Number.POSITIVE_INFINITY;
}

function bytes(n: number): string {
	return n >= 1048576 ? `${Math.round(n / 1048576)} MiB` : `${n} bytes`;
}

export function newExecution(graph: BuildGraph, opts: CliOptions, projectRoot: string, dryRun: boolean, passArgs: string[], target: int32, jobs: int32): Execution {
	return { graph, opts, projectRoot, outputs: new HashMap<int32, string>(), digests: new HashMap<int32, string>(), dryRun, ran: [], reused: [], passArgs, target, jobs, seed: opts.graphSeed, hashed: [], maxRss: buildMaxRss(opts), claimedRss: 0 };
}

function shuffle(plan: GraphNode[], seed: int32): void {
	let state: number = seed % 2147483647;
	for (let i = plan.length - 1; i > 0; i -= 1) {
		state = (state * 16807) % 2147483647;
		const j = (state % (i + 1)) as int32;
		const held = plan[i];
		plan[i] = plan[j];
		plan[j] = held;
	}
}

// A node's process: its output is collected while it runs and printed when it ends, so
// parallel nodes do not interleave.
interface Job {
	node: GraphNode;
	exe: string;
	args: string[];
	cwd: string;
	shown: string;
	child: ChildProcess | null;
	out: string;
	err: string;
	outEnded: boolean;
	errEnded: boolean;
	live: boolean;
	expectExit: int32;
	finish: (j: Job) => void;
	abandon: () => void;
}

function job(node: GraphNode, exe: string, args: string[], cwd: string, shown: string, finish: (j: Job) => void, abandon: () => void): Job {
	return { node, exe, args, cwd, shown, child: null, out: "", err: "", outEnded: false, errEnded: false, live: false, expectExit: -1, finish, abandon };
}

function storeDir(x: Execution): string {
	const root = stepStoreRoot();
	return root == "" ? join(x.projectRoot, "out/.build") : root;
}

function label(n: GraphNode): string {
	if (n.name != "") return n.name;
	if (n.description != "") return n.description;
	return `${n.kind} #${n.id}`;
}

function pathOf(x: Execution, p: GraphPath): string {
	if (p.producer < 0) return sourcePath(p);
	const out = x.outputs.get(p.producer);
	if (out == null) throw new Error(`internal: node ${p.producer} has not run before a consumer read ${p.sub}`);
	const producer = nodeById(x.graph, p.producer);
	if (producer.kind == "command" || producer.kind == "writeFiles") return p.sub == "" ? out : join(out, p.sub);
	return out;
}

function treeHash(path: string, hashed: string[]): string {
	if (!exists(path)) return "absent";
	if (!isDir(path)) {
		hashed.push(path);
		return `f:${hashFile(path)}`;
	}
	const names = readDir(path).map((e: string): string => e.endsWith("/") ? e.slice(0, e.length - 1) : e).sort();
	let acc = "";
	for (const name of names) acc = `${acc}${name}\n${treeHash(join(path, name), hashed)}\n`;
	return `d:${hashContent(acc)}`;
}

function keyPath(x: Execution, path: string): string {
	return path.startsWith(`${x.projectRoot}/`) ? path.slice(x.projectRoot.length + 1, path.length) : path;
}

function rootedPath(x: Execution, path: string): string {
	return isAbsolute(path) ? path : join(x.projectRoot, path);
}

function inputHash(x: Execution, p: GraphPath): string {
	if (p.producer >= 0) {
		const d = x.digests.get(p.producer);
		return `${p.producer}:${p.sub}:${d ?? ""}`;
	}
	const path = sourcePath(p);
	return `${keyPath(x, path)}\n${treeHash(path, x.hashed)}`;
}

function toolIdentity(program: string): string {
	const found = isAbsolute(program) ? program : findOnPath(program);
	if (found == "" || !exists(found)) throw new Error(`systemCommand: the program '${program}' is not on PATH`);
	return `${found}\n${hashFile(found)}`;
}

function modeFlag(optimize: int32): string {
	if (optimize == 1) return "--release";
	if (optimize == 2) return "--danger";
	return "";
}

function targetFlags(n: GraphNode): string[] {
	const flags: string[] = [];
	if (n.os != "") flags.push(`--os=${n.os}`);
	if (n.cpu != "") flags.push(`--cpu=${n.cpu}`);
	if (n.abi != "") flags.push(`--abi=${n.abi}`);
	return flags;
}

function runCompile(x: Execution, n: GraphNode, staticLib: boolean): Job | null {
	const entry = sourcePath(n.entry!);
	const out = join(x.projectRoot, `out/${n.name}`);
	ensureDir(dirname(out));
	const args = ["build", entry, `--output=${out}`];
	const mode = modeFlag(n.optimize);
	if (mode != "") args.push(mode);
	for (const flag of targetFlags(n)) args.push(flag);
	if (n.lto >= 0) args.push(`--lto=${["off", "full", "thin"][n.lto]}`);
	if (staticLib) args.push("--app=staticlib");
	for (const libId of n.link) args.push(`--passL=${x.outputs.get(libId)!}`);
	const compiler = n.compiler >= 0 ? x.outputs.get(n.compiler)! : execPath;
	if (x.dryRun) {
		console.log(`${compiler} ${args.join(" ")}`);
		x.outputs.set(n.id, out);
		x.digests.set(n.id, `dry:${n.id}`);
		return null;
	}
	return job(n, compiler, args, x.projectRoot, `${n.compiler >= 0 ? compiler : "msc"} build ${entry}`, (j: Job): void => {
		x.outputs.set(n.id, out);
		x.digests.set(n.id, hashFile(out));
		x.ran.push(label(n));
	}, (): void => {});
}

// The prerequisites of a make-style depfile (`out: a b \\\n c`), as absolute paths.
function depFileInputs(depFile: string, cwd: string): string[] {
	const text = (try readFile(depFile) catch "").replaceAll("\\\r\n", " ").replaceAll("\\\n", " ");
	const inputs: string[] = [];
	for (const rule of text.split("\n")) {
		const colon = rule.indexOf(": ", 0);
		if (colon < 0) continue;
		const words = rule.slice(colon + 2, rule.length).replaceAll("\\ ", "\u0000").split(" ");
		for (const word of words) {
			if (word == "") continue;
			const path = word.replaceAll("\u0000", " ");
			const absolute = isAbsolute(path) ? path : join(cwd, path);
			if (!inputs.includes(absolute)) inputs.push(absolute);
		}
	}
	return inputs;
}

function writesOutput(n: GraphNode): boolean {
	return n.stdout || n.argv.some((a: GraphArg): boolean => a.kind == ArgKind.OutputFile || a.kind == ArgKind.OutputDir || a.kind == ArgKind.DepFile);
}

function runCommand(x: Execution, n: GraphNode): Job | null {
	const extra = n.id == x.target ? x.passArgs : [];
	const live = n.expectExit < 0 && !writesOutput(n);
	const program = n.argv[0];
	let key = `${STORE_FORMAT}\ncommand\n${platform}\n${program.kind == ArgKind.Text ? toolIdentity(program.text) : "artifact"}\n`;
	for (const a of n.argv) key = `${key}${a.kind}:${a.text}:${a.path == null ? "" : inputHash(x, a.path)}\n`;
	for (const a of extra) key = `${key}arg:${a}\n`;
	if (n.cwd != null) key = `${key}cwd:${keyPath(x, pathOf(x, n.cwd))}\n`;
	for (const e of n.env) key = `${key}env:${e}\n`;
	for (const p of n.inputs) key = `${key}in:${inputHash(x, p)}\n`;
	key = `${key}stdout:${n.stdout}\nexpect:${n.expectExit}\n`;
	const store = storeDir(x);
	const known = n.sideEffects || live ? "" : storedOutput(store, key, (path: string): string => {
		x.hashed.push(rootedPath(x, path));
		return hashFile(rootedPath(x, path));
	});
	if (known != "") {
		x.outputs.set(n.id, known);
		x.digests.set(n.id, basename(known));
		x.reused.push(label(n));
		return null;
	}
	const tmp = x.dryRun ? `${store}/tmp/dry-run` : live ? "" : storeScratch(store, key);
	const argv: string[] = [];
	const depFiles: string[] = [];
	for (const a of n.argv) {
		if (a.kind == ArgKind.Text) argv.push(a.text);
		else if (a.kind == ArgKind.File) argv.push(`${a.text}${pathOf(x, a.path!)}`);
		else if (a.kind == ArgKind.OutputFile || a.kind == ArgKind.DepFile) {
			const target = join(tmp, a.path!.sub);
			if (!x.dryRun) ensureDir(dirname(target));
			argv.push(`${a.text}${target}`);
			if (a.kind == ArgKind.DepFile) depFiles.push(target);
		} else {
			const target = join(tmp, a.path!.sub);
			if (!x.dryRun) ensureDir(target);
			argv.push(`${a.text}${target}`);
		}
	}
	for (const a of extra) argv.push(a);
	const found = isAbsolute(argv[0]) ? argv[0] : findOnPath(argv[0]);
	let args = argv.slice(1, argv.length);
	let exe = found;
	if (n.env.length > 0) {
		if (platform == "windows") throw new Error(`${label(n)}: setEnvironmentVariable is not supported on Windows yet`);
		args = n.env.concat([found]).concat(args);
		exe = "/usr/bin/env";
	}
	const dir = n.cwd == null ? x.projectRoot : pathOf(x, n.cwd);
	if (x.dryRun) {
		console.log(`(cd ${dir} && ${argv.join(" ")})`);
		x.outputs.set(n.id, tmp);
		x.digests.set(n.id, `dry:${n.id}`);
		return null;
	}
	const started = job(n, exe, args, dir, argv.join(" "), (j: Job): void => {
		x.ran.push(label(n));
		if (live) {
			x.outputs.set(n.id, "");
			x.digests.set(n.id, `ran:${n.id}`);
			return;
		}
		if (n.stdout) {
			writeFile(join(tmp, "stdout"), j.out);
			j.out = "";
		}
		const read: string[] = [];
		for (const depFile of depFiles) {
			for (const input of depFileInputs(depFile, dir)) {
				if (!input.startsWith(`${tmp}/`)) read.push(`${keyPath(x, input)}\t${hashFile(input)}`);
			}
		}
		const digest = treeHash(tmp, []).slice(2);
		const placed = storePublish(store, key, tmp, digest, read);
		if (placed == "") throw new Error(`${label(n)}: cannot place its output in ${store}/o`);
		x.outputs.set(n.id, placed);
		x.digests.set(n.id, digest);
	}, (): void => { if (tmp != "") removeAll(tmp); });
	started.live = live;
	started.expectExit = n.expectExit;
	return started;
}

function runWriteFiles(x: Execution, n: GraphNode): void {
	let key = `${STORE_FORMAT}\nwriteFiles\n`;
	for (const f of n.files) key = `${key}${f.sub}\t${f.from == null ? hashContent(f.bytes) : inputHash(x, f.from!)}\n`;
	const store = storeDir(x);
	const known = storedOutput(store, key);
	if (known != "") {
		x.outputs.set(n.id, known);
		x.digests.set(n.id, basename(known));
		x.reused.push(label(n));
		return;
	}
	if (x.dryRun) {
		for (const f of n.files) console.log(`write ${f.sub}`);
		x.outputs.set(n.id, `${store}/tmp/dry-run`);
		x.digests.set(n.id, `dry:${n.id}`);
		return;
	}
	const tmp = storeScratch(store, key);
	for (const f of n.files) {
		const target = join(tmp, f.sub);
		ensureDir(dirname(target));
		const written = f.from == null ? atomicWriteFile(target, f.bytes) : atomicCopyFile(pathOf(x, f.from!), target);
		if (!written) {
			removeAll(tmp);
			throw new Error(`${label(n)}: cannot write ${f.sub}`);
		}
	}
	const digest = treeHash(tmp, []).slice(2);
	const placed = storePublish(store, key, tmp, digest);
	if (placed == "") throw new Error(`${label(n)}: cannot place its output in ${store}/o`);
	x.outputs.set(n.id, placed);
	x.digests.set(n.id, digest);
	x.ran.push(label(n));
}

function updateSources(x: Execution, n: GraphNode): void {
	x.outputs.set(n.id, "");
	for (const f of n.files) {
		const dest = sourcePath(f.dest!);
		if (x.dryRun) {
			console.log(`update ${dest}`);
			continue;
		}
		const from = f.from == null ? "" : pathOf(x, f.from!);
		const same = exists(dest) && (from == "" ? (try readFile(dest) catch "") == f.bytes : hashFile(dest) == hashFile(from));
		if (same) continue;
		ensureDir(dirname(dest));
		const written = from == "" ? atomicWriteFile(dest, f.bytes) : atomicCopyFile(from, dest);
		if (!written) throw new Error(`${label(n)}: cannot write ${dest}`);
		console.log(`updated ${keyPath(x, dest)}`);
	}
	x.ran.push(label(n));
}

function runLibrary(x: Execution, n: GraphNode): Job | null {
	if (n.from != null) {
		const path = pathOf(x, n.from);
		if (!x.dryRun && !exists(path)) throw new Error(`${label(n)}: library({ from }) names ${path}, which its producer did not write`);
		x.outputs.set(n.id, path);
		x.digests.set(n.id, x.dryRun ? `dry:${n.id}` : hashFile(path));
		return null;
	}
	return runCompile(x, n, true);
}

function installNode(x: Execution, n: GraphNode): void {
	const from = x.outputs.get(n.artifact)!;
	const artifact = nodeById(x.graph, n.artifact);
	const name = n.name != "" ? n.name : label(artifact);
	const dest = join(x.projectRoot, `out/${name}`);
	x.outputs.set(n.id, dest);
	if (x.dryRun) {
		console.log(`install ${from} -> ${dest}`);
		return;
	}
	if (from == dest) return;
	ensureDir(dirname(dest));
	if (!atomicCopyFile(from, dest)) throw new Error(`${label(n)}: cannot install ${from} at ${dest}`);
}

function runStep(x: Execution, n: GraphNode): void {
	if (x.dryRun) {
		console.log(`step: ${label(n)}`);
		return;
	}
	const vm = x.graph.run!.vm!;
	const make = x.graph.steps.get(n.id)!.field("make");
	const fn = make.field("fn").root.intVal;
	const env = make.field("env").root;
	vm.hostCallsRestricted = false;
	vmCallFunction(vm, fn as number, [env]);
	if (vm.error != "") {
		const message = vm.error;
		vm.error = "";
		throw new Error(`${label(n)}: ${message}`);
	}
	x.ran.push(label(n));
}

function startNode(x: Execution, n: GraphNode): Job | null {
	if (n.kind == "executable") return runCompile(x, n, false);
	if (n.kind == "library") return runLibrary(x, n);
	if (n.kind == "command") return runCommand(x, n);
	if (n.kind == "install") installNode(x, n);
	else if (n.kind == "step") runStep(x, n);
	else if (n.kind == "writeFiles") runWriteFiles(x, n);
	else if (n.kind == "updateSourceFiles") updateSources(x, n);
	else throw new Error(`build.ms: msc does not know the node kind '${n.kind}' of ${label(n)}`);
	return null;
}

function order(g: BuildGraph, id: int32, done: HashSet<int32>, active: HashSet<int32>, into: GraphNode[]): void {
	if (done.has(id)) return;
	const n = nodeById(g, id);
	if (active.has(id)) throw new Error(`build.ms: ${label(n)} depends on itself`);
	active.add(id);
	for (const dep of n.deps) order(g, dep, done, active, into);
	active.delete(id);
	done.add(id);
	into.push(n);
}

function drain(j: Job, stream: ChildStream, timeoutMs: int32): boolean {
	const got = j.child!.read(stream, timeoutMs);
	if (!got.ok) return false;
	if (stream == ChildStream.Stdout) {
		if (j.live) writeStdout(got.value.data);
		else j.out = `${j.out}${got.value.data}`;
		if (got.value.ended) j.outEnded = true;
	} else {
		if (j.live) writeStderr(got.value.data);
		else j.err = `${j.err}${got.value.data}`;
		if (got.value.ended) j.errEnded = true;
	}
	return true;
}

// True once both pipes of the job's process have ended, so its output is complete.
function pump(j: Job, timeoutMs: int32): boolean {
	let moved = false;
	if (!j.outEnded) moved = drain(j, ChildStream.Stdout, timeoutMs);
	if (!j.errEnded) moved = drain(j, ChildStream.Stderr, moved ? 0 : timeoutMs) || moved;
	return j.outEnded && j.errEnded;
}

function settle(j: Job): string {
	const status = j.child!.wait(60000);
	j.child!.close();
	const code = status.ok ? status.value.code : -1;
	const peak = j.child!.peakRss();
	if (status.ok && j.node.maxRss > 0 && peak != null && peak > j.node.maxRss) {
		if (j.out != "") console.log(j.out.trimEnd());
		if (j.err != "") console.log(j.err.trimEnd());
		j.abandon();
		return `${label(j.node)}: ${j.shown} peaked at ${bytes(peak)}, above its declared maxRss of ${bytes(j.node.maxRss)}`;
	}
	const signal = status.ok ? status.value.signal : 0;
	if (signal != 0 || code != Math.max(j.expectExit, 0)) {
		if (j.out != "") console.log(j.out.trimEnd());
		if (j.err != "") console.log(j.err.trimEnd());
		j.abandon();
		const how = signal != 0 ? `was killed by signal ${signal}` : `exited with ${code}`;
		return `${label(j.node)}: ${j.shown} ${how}${j.expectExit >= 0 ? `, expected ${j.expectExit}` : ""}`;
	}
	try {
		j.finish(j);
	} catch (e) {
		return e.message;
	}
	if (j.out != "") console.log(j.out.trimEnd());
	if (j.err != "") console.log(j.err.trimEnd());
	return "";
}

export function executeNode(x: Execution, id: int32): string {
	const subject = `graph:${x.projectRoot}`;
	const writes = loadFileHashes(subject);
	try {
		return executePlan(x, id);
	} finally {
		saveFileHashes(subject, x.hashed, writes);
	}
}

function executePlan(x: Execution, id: int32): string {
	const plan: GraphNode[] = [];
	order(x.graph, id, new HashSet<int32>(), new HashSet<int32>(), plan);
	if (x.seed != 0) shuffle(plan, x.seed);
	for (const n of plan) {
		if (n.maxRss > x.maxRss) throw new Error(`${label(n)}: declares maxRss ${bytes(n.maxRss)}, above the ${bytes(x.maxRss)} this build may use (--maxrss)`);
	}
	const done = new HashSet<int32>();
	const started = new HashSet<int32>();
	const running: Job[] = [];
	let failure = "";
	while (done.size < plan.length) {
		let moved = false;
		for (const n of plan) {
			if (failure != "" || started.has(n.id) || running.length >= x.jobs) continue;
			if (!n.deps.every((d: int32): boolean => done.has(d))) continue;
			if (x.claimedRss + n.maxRss > x.maxRss) continue;
			started.add(n.id);
			moved = true;
			try {
				const j = startNode(x, n);
				if (j == null) {
					done.add(n.id);
					continue;
				}
				const child = spawn(j.exe, j.args, { cwd: j.cwd });
				if (!child.ok) {
					j.abandon();
					failure = `${label(n)}: cannot start ${j.shown}: ${child.error.message}`;
					continue;
				}
				j.child = child.value;
				j.child!.closeStdin();
				x.claimedRss += n.maxRss;
				running.push(j);
			} catch (e) {
				failure = e.message;
			}
		}
		for (let i = running.length - 1; i >= 0; i -= 1) {
			const j = running[i];
			if (!pump(j, 0)) continue;
			running.splice(i, 1);
			x.claimedRss -= j.node.maxRss;
			const problem = settle(j);
			if (problem != "" && failure == "") failure = problem;
			done.add(j.node.id);
			moved = true;
		}
		if (failure != "" && running.length == 0) throw new Error(failure);
		if (!moved && running.length > 0) pump(running[0], 10);
		else if (!moved) throw new Error(`internal: the build graph stalled with ${plan.length - done.size} node(s) left`);
	}
	return x.outputs.get(id) ?? "";
}

// A step's make is a closure of the configure VM, which a cached graph does not have.
export function planRunsStep(g: BuildGraph, id: int32): boolean {
	const plan: GraphNode[] = [];
	order(g, id, new HashSet<int32>(), new HashSet<int32>(), plan);
	return plan.some((n: GraphNode): boolean => n.kind == "step");
}
