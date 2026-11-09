import { Node, NodeKind, bindSym, expansionFile } from "std/meta";
import { resolve, join } from "std/fs/path";

export enum Optimize { Debug, ReleaseSafe, ReleaseFast }

export enum Linkage { Static, Dynamic }

export interface Target {
	os: string;
	cpu: string;
	abi: string;
}

export interface LazyPath {
	owner: string;
	sub: string;
	producer: BuildNode | null;
}

export enum ArgKind { Text, File, OutputFile, OutputDir, DepFile }

export interface CommandArg {
	kind: ArgKind;
	text: string;
	path: LazyPath | null;
}

export interface EnvVar {
	name: string;
	value: string;
}

let nextId: int32 = 0;

export class BuildNode {
	id: int32;
	kind: string;
	description: string;
	deps: BuildNode[];
	constructor(kind: string, description: string) {
		nextId += 1;
		this.id = nextId;
		this.kind = kind;
		this.description = description;
		this.deps = [];
	}
}

export function pathFrom(owner: string, sub: string): LazyPath {
	return { owner, sub, producer: null };
}

export macro path(sub: Node): Node {
	const file = expansionFile();
	const owner: Node = { kind: NodeKind.StringLiteral, line: sub.line, column: sub.column, value: file.substring(0, file.lastIndexOf("/")) };
	return { kind: NodeKind.CallExpr, line: sub.line, column: sub.column, callee: bindSym("pathFrom"), arguments: [owner, sub], isDirectCall: false, resolvedOverloadIdx: -1 };
}

extern function msBuildGlob(base: string, pattern: string): string;

export function globFrom(owner: string, pattern: string): LazyPath[] {
	const listing = msBuildGlob(owner, pattern);
	return listing == "" ? [] : listing.split("\n").map((sub: string): LazyPath => pathFrom(owner, sub));
}

// The files matching `pattern` under the directory of the file that calls `glob()`, sorted;
// dot-directories are not entered. The configure cache lists them again before reusing a graph.
export macro glob(pattern: Node): Node {
	const file = expansionFile();
	const owner: Node = { kind: NodeKind.StringLiteral, line: pattern.line, column: pattern.column, value: file.substring(0, file.lastIndexOf("/")) };
	return { kind: NodeKind.CallExpr, line: pattern.line, column: pattern.column, callee: bindSym("globFrom"), arguments: [owner, pattern], isDirectCall: false, resolvedOverloadIdx: -1 };
}

export function file(this dir: LazyPath, sub: string): LazyPath {
	return { owner: dir.owner, sub: join(dir.sub, sub), producer: dir.producer };
}

export function resolved(this p: LazyPath): string {
	if (p.producer != null) throw new Error(`${p.sub} is an output of node ${p.producer.id}; its path exists only while the graph runs`);
	return resolve(p.sub, p.owner);
}

function dependOn(node: BuildNode, p: LazyPath): void {
	const producer = p.producer;
	if (producer != null && !node.deps.includes(producer)) node.deps.push(producer);
}

function generated(node: BuildNode, sub: string): LazyPath {
	return { owner: "", sub, producer: node };
}

export class Library extends BuildNode {
	linkage: Linkage;
	entry: LazyPath | null;
	from: LazyPath | null;
	target: Target;
	optimize: Optimize;
	constructor(linkage: Linkage, entry: LazyPath | null, from: LazyPath | null, target: Target, optimize: Optimize) {
		super("library", "");
		this.linkage = linkage;
		this.entry = entry;
		this.from = from;
		this.target = target;
		this.optimize = optimize;
		if (entry != null) dependOn(this, entry);
		if (from != null) dependOn(this, from);
	}
}

export class Executable extends BuildNode {
	entry: LazyPath;
	target: Target;
	optimize: Optimize;
	link: Library[];
	constructor(entry: LazyPath, target: Target, optimize: Optimize, link: Library[]) {
		super("executable", "");
		this.entry = entry;
		this.target = target;
		this.optimize = optimize;
		this.link = link;
		dependOn(this, entry);
		for (const lib of link) {
			if (!this.deps.includes(lib)) this.deps.push(lib);
		}
	}
}

export class Command extends BuildNode {
	argv: CommandArg[];
	cwd: LazyPath | null;
	inputs: LazyPath[];
	env: EnvVar[];
	stdout: boolean;
	constructor(argv: string[]) {
		super("command", "");
		this.argv = [];
		for (const text of argv) this.argv.push({ kind: ArgKind.Text, text, path: null });
		this.cwd = null;
		this.inputs = [];
		this.env = [];
		this.stdout = false;
	}
}

export class RunArtifact extends BuildNode {
	artifact: Executable;
	args: string[];
	constructor(artifact: Executable, args: string[]) {
		super("run", "");
		this.artifact = artifact;
		this.args = args;
		this.deps.push(artifact);
	}
}

export class Install extends BuildNode {
	artifact: BuildNode;
	constructor(artifact: BuildNode) {
		super("install", "");
		this.artifact = artifact;
		this.deps.push(artifact);
	}
}

export class CustomStep extends BuildNode {
	make: () => void;
	constructor(description: string, inputs: BuildNode[], make: () => void) {
		super("step", description);
		this.make = make;
		for (const input of inputs) {
			if (!this.deps.includes(input)) this.deps.push(input);
		}
	}
}

export function host(): Target {
	return { os: "", cpu: "", abi: "" };
}

extern function msBuildOption(name: string, description: string): string;

// `msc build -Dname=value`; a bare `-Dname` gives "true". Null when the command line does not name it.
export function option(name: string, description: string): string | null {
	const given = msBuildOption(name, description);
	return given == "" ? null : given.slice(1, given.length);
}

// `-Doptimize=Debug|ReleaseSafe|ReleaseFast`, or `--release` / `--danger`; Debug otherwise.
export function standardOptimizeOption(): Optimize {
	const given = option("optimize", "Debug, ReleaseSafe or ReleaseFast; --release and --danger name the last two");
	if (given == null || given == "Debug") return Optimize.Debug;
	if (given == "ReleaseSafe") return Optimize.ReleaseSafe;
	if (given == "ReleaseFast") return Optimize.ReleaseFast;
	throw new Error(`optimize: '${given}' is not Debug, ReleaseSafe or ReleaseFast`);
}

// `--os`, `--cpu` and `--abi` (or `-Dos=` …); the host for each one not given.
export function standardTargetOptions(): Target {
	return {
		os: option("os", "the target os, as --os takes it") ?? "",
		cpu: option("cpu", "the target cpu, as --cpu takes it") ?? "",
		abi: option("abi", "the libc of a linux target, as --abi takes it") ?? "",
	};
}

export interface ExecutableOptions {
	entry: LazyPath;
	target?: Target;
	optimize?: Optimize;
	link?: Library[];
}

export function executable(o: ExecutableOptions): Executable {
	return new Executable(o.entry, o.target ?? host(), o.optimize ?? Optimize.Debug, o.link ?? []);
}

export interface LibraryOptions {
	linkage: Linkage;
	entry?: LazyPath;
	from?: LazyPath;
	target?: Target;
	optimize?: Optimize;
}

export function library(o: LibraryOptions): Library {
	const entry = o.entry ?? null;
	const from = o.from ?? null;
	if ((entry == null) == (from == null)) throw new Error("library() takes exactly one of entry (a MetaScript module to compile) or from (a built file)");
	return new Library(o.linkage, entry, from, o.target ?? host(), o.optimize ?? Optimize.Debug);
}

export function systemCommand(argv: string[]): Command {
	if (argv.length == 0) throw new Error("systemCommand() needs the program as its first argument");
	return new Command(argv);
}

export function addArgs(this c: Command, args: string[]): void {
	for (const text of args) c.argv.push({ kind: ArgKind.Text, text, path: null });
}

export function addFileArg(this c: Command, p: LazyPath): void {
	c.argv.push({ kind: ArgKind.File, text: "", path: p });
	dependOn(c, p);
}

export function addFileInput(this c: Command, p: LazyPath): void {
	c.inputs.push(p);
	dependOn(c, p);
}

export function addOutputFileArg(this c: Command, name: string): LazyPath {
	const out = generated(c, name);
	c.argv.push({ kind: ArgKind.OutputFile, text: "", path: out });
	return out;
}

export function addPrefixedOutputDirectoryArg(this c: Command, prefix: string, name: string): LazyPath {
	const out = generated(c, name);
	c.argv.push({ kind: ArgKind.OutputDir, text: prefix, path: out });
	return out;
}

// The tool writes a make-style depfile there; the files it lists become inputs of this command.
export function addDepFileOutputArg(this c: Command, name: string): LazyPath {
	return c.addPrefixedDepFileOutputArg("", name);
}

export function addPrefixedDepFileOutputArg(this c: Command, prefix: string, name: string): LazyPath {
	const out = generated(c, name);
	c.argv.push({ kind: ArgKind.DepFile, text: prefix, path: out });
	return out;
}

export function captureStdOut(this c: Command): LazyPath {
	c.stdout = true;
	return generated(c, "stdout");
}

export function setCwd(this c: Command, p: LazyPath): void {
	c.cwd = p;
	dependOn(c, p);
}

export function setEnvironmentVariable(this c: Command, name: string, value: string): void {
	c.env.push({ name, value });
}

export function runArtifact(artifact: Executable, args: string[] = []): RunArtifact {
	return new RunArtifact(artifact, args);
}

export function installArtifact(artifact: BuildNode): Install {
	return new Install(artifact);
}

export interface StepOptions {
	description: string;
	inputs?: BuildNode[];
	make: () => void;
}

export function step(o: StepOptions): CustomStep {
	return new CustomStep(o.description, o.inputs ?? [], o.make);
}

export function describe(this n: BuildNode, description: string): void {
	n.description = description;
}
