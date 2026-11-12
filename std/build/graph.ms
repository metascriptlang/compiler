import { Node, NodeKind, bindSym, expansionFile } from "std/meta";
import { resolve, join } from "std/fs/path";

export enum Optimize { Debug, ReleaseSafe, ReleaseFast }

export enum Linkage { Static, Dynamic }

export enum LtoMode { None, Full, Thin }

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

export enum CheckedStream { StdOut, StdErr }

export interface OutputCheck {
	stream: CheckedStream;
	exact: boolean;
	text: string;
}

export interface EnvVar {
	name: string;
	value: string;
	path: LazyPath | null;
}

let nextId: int32 = 0;

export class BuildNode {
	id: int32;
	kind: string;
	description: string;
	deps: BuildNode[];
	maxRss: number;
	constructor(kind: string, description: string) {
		nextId += 1;
		this.id = nextId;
		this.kind = kind;
		this.description = description;
		this.deps = [];
		this.maxRss = 0;
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
	lto: LtoMode | null;
	compiler: Executable | null;
	constructor(entry: LazyPath, target: Target, optimize: Optimize, link: Library[], lto: LtoMode | null, compiler: Executable | null) {
		super("executable", "");
		this.entry = entry;
		this.target = target;
		this.optimize = optimize;
		this.link = link;
		this.lto = lto;
		this.compiler = compiler;
		dependOn(this, entry);
		for (const lib of link) {
			if (!this.deps.includes(lib)) this.deps.push(lib);
		}
		if (compiler != null) this.deps.push(compiler);
	}
}

export class Command extends BuildNode {
	argv: CommandArg[];
	cwd: LazyPath | null;
	inputs: LazyPath[];
	env: EnvVar[];
	stdout: boolean;
	hasSideEffects: boolean;
	expectedExit: int32 | null;
	checks: OutputCheck[];
	constructor() {
		super("command", "");
		this.argv = [];
		this.cwd = null;
		this.inputs = [];
		this.env = [];
		this.stdout = false;
		this.hasSideEffects = false;
		this.expectedExit = null;
		this.checks = [];
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
	make: (() => void) | null;
	constructor(description: string, inputs: BuildNode[], make: (() => void) | null) {
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

extern function msBuildMscExe(): string;

export function mscExe(): string {
	return msBuildMscExe();
}

extern function msBuildOption(name: string, description: string): string;

function given(name: string, description: string): string | null {
	const text = msBuildOption(name, description);
	return text == "" ? null : text.slice(1, text.length);
}

// `msc build -Dname=value`; a bare `-Dname` gives "true". Null when the command line does not name it.
export function option(name: string, description: string): string | null {
	return given(name, description);
}

export function option(name: string, description: string, fallback: string): string {
	return given(name, `${description} (default ${fallback})`) ?? fallback;
}

export function option(name: string, description: string, fallback: number): number {
	const text = given(name, `${description} (default ${fallback})`);
	if (text == null) return fallback;
	const value = Number(text);
	if (text.trim() == "" || Number.isNaN(value)) throw new Error(`${name}: '${text}' is not a number`);
	return value;
}

export function option(name: string, description: string, fallback: boolean): boolean {
	const text = given(name, `${description} (default ${fallback})`);
	if (text == null) return fallback;
	if (text != "true" && text != "false") throw new Error(`${name}: '${text}' is not true or false`);
	return text == "true";
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
	lto?: LtoMode;
	compiler?: Executable;
	maxRss?: number;
}

export function executable(o: ExecutableOptions): Executable {
	const made = new Executable(o.entry, o.target ?? host(), o.optimize ?? Optimize.Debug, o.link ?? [], o.lto ?? null, o.compiler ?? null);
	made.maxRss = o.maxRss ?? 0;
	return made;
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

export type Arg = string | LazyPath | Executable;

export interface RunOptions {
	env?: Record<string, Arg>;
	cwd?: LazyPath;
	inputs?: LazyPath[];
	expectExitCode?: int32;
	description?: string;
	maxRss?: number;
}

function withOptions(c: Command, o: RunOptions): Command {
	const env = o.env;
	if (env != null) {
		for (const [name, value] of env) c.setEnvironmentVariable(name, value);
	}
	if (o.cwd != null) c.setCwd(o.cwd);
	for (const p of o.inputs ?? []) c.addFileInput(p);
	if (o.expectExitCode != null) c.expectExitCode(o.expectExitCode);
	if (o.description != null) c.describe(o.description);
	c.maxRss = o.maxRss ?? 0;
	return c;
}

function fileOf(a: LazyPath | Executable): LazyPath {
	if (a instanceof Executable) return a.getEmittedBin();
	return a;
}

function addArg(c: Command, a: Arg): void {
	if (typeof a == "string") c.argv.push({ kind: ArgKind.Text, text: a, path: null });
	else c.addFileArg(fileOf(a));
}

export function systemCommand<A extends Arg>(argv: A[], o: RunOptions = {}): Command {
	if (argv.length == 0) throw new Error("systemCommand() needs the program as its first argument");
	const c = new Command();
	for (const a of argv) addArg(c, a);
	return withOptions(c, o);
}

export function addArgs(this c: Command, args: string[]): void {
	for (const text of args) c.argv.push({ kind: ArgKind.Text, text, path: null });
}

export function addFileArg(this c: Command, p: LazyPath): void {
	c.addPrefixedFileArg("", p);
}

export function addPrefixedFileArg(this c: Command, prefix: string, p: LazyPath): void {
	c.argv.push({ kind: ArgKind.File, text: prefix, path: p });
	dependOn(c, p);
}

export function getEmittedBin(this a: Executable): LazyPath {
	return generated(a, "");
}

export function addArtifactArg(this c: Command, a: Executable): void {
	c.addPrefixedFileArg("", a.getEmittedBin());
}

export function addPrefixedArtifactArg(this c: Command, prefix: string, a: Executable): void {
	c.addPrefixedFileArg(prefix, a.getEmittedBin());
}

export function expectExitCode(this c: Command, code: int32): void {
	c.expectedExit = code;
}

export function expectStdOutEqual(this c: Command, bytes: string): void {
	c.checks.push({ stream: CheckedStream.StdOut, exact: true, text: bytes });
	if (c.expectedExit == null) c.expectExitCode(0);
}

export function expectStdErrEqual(this c: Command, bytes: string): void {
	c.checks.push({ stream: CheckedStream.StdErr, exact: true, text: bytes });
}

export function expectStdOutMatch(this c: Command, text: string): void {
	c.checks.push({ stream: CheckedStream.StdOut, exact: false, text });
}

export function expectStdErrMatch(this c: Command, text: string): void {
	c.checks.push({ stream: CheckedStream.StdErr, exact: false, text });
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

export function setEnvironmentVariable(this c: Command, name: string, value: Arg): void {
	if (typeof value == "string") {
		c.env.push({ name, value, path: null });
		return;
	}
	const p = fileOf(value);
	c.env.push({ name, value: "", path: p });
	dependOn(c, p);
}

export function runArtifact(artifact: Executable, args: string[] = [], o: RunOptions = {}): Command {
	const c = new Command();
	c.addArtifactArg(artifact);
	c.addArgs(args);
	return withOptions(c, o);
}

export interface TestOptions {
	entry: LazyPath;
	testsInDir?: boolean;
	optimize?: Optimize;
	compiler?: Executable;
	args?: string[];
	maxRss?: number;
}

export function test(o: TestOptions): Command {
	const compiler = o.compiler ?? null;
	const c = compiler == null ? systemCommand([mscExe(), "test"]) : runArtifact(compiler, ["test"]);
	c.addFileArg(o.entry);
	if (o.testsInDir ?? false) c.addArgs(["--tests-in-dir"]);
	const optimize = o.optimize ?? Optimize.Debug;
	if (optimize == Optimize.ReleaseSafe) c.addArgs(["--release"]);
	if (optimize == Optimize.ReleaseFast) c.addArgs(["--danger"]);
	c.addArgs(o.args ?? []);
	c.addPrefixedDepFileOutputArg("--depfile=", "inputs.d");
	c.expectExitCode(0);
	c.maxRss = o.maxRss ?? 0;
	return c;
}

export function installArtifact(artifact: BuildNode): Install {
	return new Install(artifact);
}

export interface StepOptions {
	description: string;
	inputs?: BuildNode[];
	make?: () => void;
}

export function step(o: StepOptions): CustomStep {
	return new CustomStep(o.description, o.inputs ?? [], o.make ?? null);
}

export function describe(this n: BuildNode, description: string): void {
	n.description = description;
}

export interface FileWrite {
	sub: string;
	bytes: string;
	from: LazyPath | null;
	dest: LazyPath | null;
}

export class WriteFiles extends BuildNode {
	files: FileWrite[];
	constructor() {
		super("writeFiles", "");
		this.files = [];
	}
}

export function writeFiles(): WriteFiles {
	return new WriteFiles();
}

export function add(this w: WriteFiles, sub: string, bytes: string): LazyPath {
	w.files.push({ sub, bytes, from: null, dest: null });
	return generated(w, sub);
}

export function addCopyFile(this w: WriteFiles, source: LazyPath, sub: string): LazyPath {
	dependOn(w, source);
	w.files.push({ sub, bytes: "", from: source, dest: null });
	return generated(w, sub);
}

export function getDirectory(this w: WriteFiles): LazyPath {
	return generated(w, "");
}

export class UpdateSourceFiles extends BuildNode {
	files: FileWrite[];
	constructor() {
		super("updateSourceFiles", "");
		this.files = [];
	}
}

export function updateSourceFiles(): UpdateSourceFiles {
	return new UpdateSourceFiles();
}

export function addCopyFileToSource(this u: UpdateSourceFiles, source: LazyPath, dest: LazyPath): void {
	dependOn(u, source);
	u.files.push({ sub: "", bytes: "", from: source, dest });
}

export function addBytesToSource(this u: UpdateSourceFiles, bytes: string, dest: LazyPath): void {
	u.files.push({ sub: "", bytes, from: null, dest });
}
