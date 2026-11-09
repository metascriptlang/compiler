import { BuildGraph, GraphNode, GraphPath, ArgKind, nodeById, sourcePath } from "./configure";
import { CliOptions } from "../options";
import { hashFile } from "../cache";
import { hashContent } from "../../utils/contentHash";
import { globalCacheRoot } from "../../utils/cachePaths";
import { atomicWriteFile, renameReplace } from "../io";
import { exists, isDir, readDir, readFile, writeFile, ensureDir, removeAll, rename, copyFile } from "std/fs";
import { join, dirname, basename, isAbsolute } from "std/fs/path";
import { execFile, execFileCapture, execPath, platform, findOnPath } from "std/process";
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
}

export function newExecution(graph: BuildGraph, opts: CliOptions, projectRoot: string, dryRun: boolean, passArgs: string[]): Execution {
	return { graph, opts, projectRoot, outputs: new HashMap<int32, string>(), digests: new HashMap<int32, string>(), dryRun, ran: [], reused: [], passArgs };
}

function storeDir(x: Execution): string {
	const root = globalCacheRoot();
	return root == "" ? join(x.projectRoot, "out/.build") : `${root}/build`;
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
	if (producer.kind == "command") return p.sub == "" ? out : join(out, p.sub);
	return out;
}

function treeHash(path: string): string {
	if (!exists(path)) return `absent:${path}`;
	if (!isDir(path)) return `f:${hashFile(path)}`;
	const names = readDir(path).map((e: string): string => e.endsWith("/") ? e.slice(0, e.length - 1) : e).sort();
	let acc = "";
	for (const name of names) acc = `${acc}${name}\n${treeHash(join(path, name))}\n`;
	return `d:${hashContent(acc)}`;
}

function inputHash(x: Execution, p: GraphPath): string {
	if (p.producer >= 0) {
		const d = x.digests.get(p.producer);
		return `${p.producer}:${p.sub}:${d ?? ""}`;
	}
	const path = sourcePath(p);
	return `${path}\n${treeHash(path)}`;
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

function runCompile(x: Execution, n: GraphNode, staticLib: boolean): void {
	const entry = sourcePath(n.entry!);
	if (n.name == "") n.name = basename(entry).replace(".ms", "");
	const outDir = join(x.projectRoot, "out");
	ensureDir(outDir);
	const out = join(outDir, n.name);
	const args = ["build", entry, `--output=${out}`];
	const mode = modeFlag(n.optimize);
	if (mode != "") args.push(mode);
	for (const flag of targetFlags(n)) args.push(flag);
	if (staticLib) args.push("--app=staticlib");
	for (const libId of n.link) args.push(`--passL=${x.outputs.get(libId)!}`);
	if (x.dryRun) {
		console.log(`${execPath} ${args.join(" ")}`);
		x.outputs.set(n.id, out);
		x.digests.set(n.id, `dry:${n.id}`);
		return;
	}
	const code = execFile(execPath, args);
	if (code != 0) throw new Error(`${label(n)}: msc build ${entry} exited with ${code}`);
	x.outputs.set(n.id, out);
	x.digests.set(n.id, hashFile(out));
	x.ran.push(label(n));
}

function runCommand(x: Execution, n: GraphNode): void {
	let key = `${STORE_FORMAT}\ncommand\n${platform}\n${toolIdentity(n.argv[0].text)}\n`;
	for (const a of n.argv) key = `${key}${a.kind}:${a.text}:${a.path == null ? "" : inputHash(x, a.path)}\n`;
	if (n.cwd != null) key = `${key}cwd:${pathOf(x, n.cwd)}\n`;
	for (const e of n.env) key = `${key}env:${e}\n`;
	for (const p of n.inputs) key = `${key}in:${inputHash(x, p)}\n`;
	key = `${key}stdout:${n.stdout}\n`;
	const store = storeDir(x);
	const manifest = `${store}/m/${hashContent(key)}`;
	const known = exists(manifest) ? (try readFile(manifest) catch "") : "";
	if (known != "" && exists(`${store}/o/${known}`)) {
		x.outputs.set(n.id, `${store}/o/${known}`);
		x.digests.set(n.id, known);
		x.reused.push(label(n));
		return;
	}
	const tmp = `${store}/tmp/${hashContent(`${key}${performance.now()}`)}`;
	if (!x.dryRun) ensureDir(tmp);
	const argv: string[] = [];
	for (const a of n.argv) {
		if (a.kind == ArgKind.Text) argv.push(a.text);
		else if (a.kind == ArgKind.File) argv.push(pathOf(x, a.path!));
		else if (a.kind == ArgKind.OutputFile) {
			const target = join(tmp, a.path!.sub);
			if (!x.dryRun) ensureDir(dirname(target));
			argv.push(target);
		} else {
			const target = join(tmp, a.path!.sub);
			if (!x.dryRun) ensureDir(target);
			argv.push(`${a.text}${target}`);
		}
	}
	const program = isAbsolute(argv[0]) ? argv[0] : findOnPath(argv[0]);
	let args = argv.slice(1, argv.length);
	let exe = program;
	if (n.env.length > 0) {
		if (platform == "windows") throw new Error(`${label(n)}: setEnvironmentVariable is not supported on Windows yet`);
		args = n.env.concat([program]).concat(args);
		exe = "/usr/bin/env";
	}
	const dir = n.cwd == null ? x.projectRoot : pathOf(x, n.cwd);
	if (x.dryRun) {
		console.log(`(cd ${dir} && ${argv.join(" ")})`);
		x.outputs.set(n.id, tmp);
		x.digests.set(n.id, `dry:${n.id}`);
		return;
	}
	const r = execFileCapture(exe, args, dir);
	if (!r.ok) {
		removeAll(tmp);
		throw new Error(`${label(n)}: ${argv.join(" ")} failed: ${r.error.message}\n${r.error.errorOutput}`);
	}
	if (n.stdout) writeFile(join(tmp, "stdout"), r.value);
	const digest = treeHash(tmp).slice(2);
	const placed = `${store}/o/${digest}`;
	ensureDir(`${store}/o`);
	if (exists(placed)) removeAll(tmp);
	else if (!rename(tmp, placed).ok && !exists(placed)) throw new Error(`${label(n)}: cannot place its output at ${placed}`);
	ensureDir(`${store}/m`);
	atomicWriteFile(manifest, digest);
	x.outputs.set(n.id, placed);
	x.digests.set(n.id, digest);
	x.ran.push(label(n));
}

function runLibrary(x: Execution, n: GraphNode): void {
	if (n.from != null) {
		const path = pathOf(x, n.from);
		if (!x.dryRun && !exists(path)) throw new Error(`${label(n)}: library({ from }) names ${path}, which its producer did not write`);
		x.outputs.set(n.id, path);
		x.digests.set(n.id, x.dryRun ? `dry:${n.id}` : hashFile(path));
		return;
	}
	runCompile(x, n, true);
}

function runArtifactNode(x: Execution, n: GraphNode): void {
	const exe = x.outputs.get(n.artifact)!;
	const args = n.args.concat(x.passArgs);
	if (x.dryRun) {
		console.log(`${exe} ${args.join(" ")}`);
		return;
	}
	const code = execFile(exe, args);
	if (code != 0) throw new Error(`${label(n)}: ${exe} exited with ${code}`);
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
	const staged = `${dest}.${performance.now()}.tmp`;
	if (!copyFile(from, staged).ok || !renameReplace(staged, dest)) throw new Error(`${label(n)}: cannot install ${from} at ${dest}`);
}

function runStep(x: Execution, n: GraphNode): void {
	if (x.dryRun) {
		console.log(`step: ${label(n)}`);
		return;
	}
	const vm = x.graph.run.vm!;
	const make = n.live.field("make");
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

function runNode(x: Execution, n: GraphNode): void {
	if (n.kind == "executable") runCompile(x, n, false);
	else if (n.kind == "library") runLibrary(x, n);
	else if (n.kind == "command") runCommand(x, n);
	else if (n.kind == "run") runArtifactNode(x, n);
	else if (n.kind == "install") installNode(x, n);
	else if (n.kind == "step") runStep(x, n);
	else throw new Error(`build.ms: msc does not know the node kind '${n.kind}' of ${label(n)}`);
}

function visit(x: Execution, id: int32, done: HashSet<int32>, active: HashSet<int32>): void {
	if (done.has(id)) return;
	const n = nodeById(x.graph, id);
	if (active.has(id)) throw new Error(`build.ms: ${label(n)} depends on itself`);
	active.add(id);
	for (const dep of n.deps) visit(x, dep, done, active);
	runNode(x, n);
	active.delete(id);
	done.add(id);
}

export function executeNode(x: Execution, id: int32): string {
	visit(x, id, new HashSet<int32>(), new HashSet<int32>());
	return x.outputs.get(id) ?? "";
}
