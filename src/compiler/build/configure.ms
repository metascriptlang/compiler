import { compileRaiser, runRaiser, setDiagnosticHook } from "../compile";
import { setRecoverableBuild, BUILD_STOPPED } from "../io";
import { CliOptions, Target, newCliOptions, seedOptionDefines } from "../options";
import { setParserDefines } from "../../parser/context";
import { ModuleError } from "../../module/graph";
import { RaiserModule } from "../../raiser/module";
import { RaiserContext } from "../../raiser/context";
import { RaiserValueKind } from "../../raiser/value";
import { RaiserHostValue, field, length, at, text } from "../../raiser/marshal";
import { resolve } from "std/fs/path";

export enum ArgKind { Text, File, OutputFile, OutputDir }

export interface GraphPath {
	owner: string;
	sub: string;
	producer: int32;
}

export interface GraphArg {
	kind: ArgKind;
	text: string;
	path: GraphPath | null;
}

export interface GraphNode {
	id: int32;
	kind: string;
	name: string;
	description: string;
	deps: int32[];
	entry: GraphPath | null;
	from: GraphPath | null;
	os: string;
	cpu: string;
	abi: string;
	optimize: int32;
	linkage: int32;
	link: int32[];
	argv: GraphArg[];
	cwd: GraphPath | null;
	inputs: GraphPath[];
	env: string[];
	stdout: boolean;
	artifact: int32;
	args: string[];
	live: RaiserHostValue;
}

export interface BuildGraph {
	buildFile: string;
	nodes: GraphNode[];
	exportNames: string[];
	exportIds: int32[];
	defaultId: int32;
	run: RaiserContext;
}

export interface ConfigureProblem {
	file: string;
	line: int32;
	message: string;
}

export function sourcePath(p: GraphPath): string {
	return resolve(p.sub, p.owner);
}

function live(run: RaiserContext, root: RaiserHostValue["root"]): RaiserHostValue {
	return { root, arrayHeap: run.vm!.arrayHeap, objectHeap: run.vm!.objectHeap };
}

function isNil(v: RaiserHostValue): boolean {
	return v.root.kind == RaiserValueKind.Nil;
}

function intOf(v: RaiserHostValue): int32 {
	return v.root.intVal as int32;
}

function strings(v: RaiserHostValue): string[] {
	const out: string[] = [];
	for (let i = 0; i < v.length(); i += 1) out.push(v.at(i).text());
	return out;
}

function isNode(v: RaiserHostValue): boolean {
	if (v.root.kind != RaiserValueKind.Object) return false;
	return !isNil(v.field("id")) && !isNil(v.field("kind")) && !isNil(v.field("deps"));
}

interface Reader {
	nodes: GraphNode[];
	seen: int32[];
}

function readPath(r: Reader, v: RaiserHostValue): GraphPath | null {
	if (isNil(v)) return null;
	const producer = v.field("producer");
	let id: int32 = -1;
	if (!isNil(producer)) id = readNode(r, producer);
	return { owner: v.field("owner").text(), sub: v.field("sub").text(), producer: id };
}

function readPaths(r: Reader, v: RaiserHostValue): GraphPath[] {
	const out: GraphPath[] = [];
	for (let i = 0; i < v.length(); i += 1) {
		const p = readPath(r, v.at(i));
		if (p != null) out.push(p);
	}
	return out;
}

function optionalField(v: RaiserHostValue, name: string): RaiserHostValue | null {
	const got = v.field(name);
	return isNil(got) ? null : got;
}

function readNode(r: Reader, v: RaiserHostValue): int32 {
	const id = intOf(v.field("id"));
	if (r.seen.includes(id)) return id;
	r.seen.push(id);
	const node: GraphNode = {
		id, kind: v.field("kind").text(), name: "", description: v.field("description").text(), deps: [],
		entry: null, from: null, os: "", cpu: "", abi: "", optimize: 0, linkage: 0, link: [],
		argv: [], cwd: null, inputs: [], env: [], stdout: false, artifact: -1, args: [], live: v,
	};
	r.nodes.push(node);
	const deps = v.field("deps");
	for (let i = 0; i < deps.length(); i += 1) node.deps.push(readNode(r, deps.at(i)));
	if (node.kind == "executable" || node.kind == "library") {
		const entry = optionalField(v, "entry");
		if (entry != null) node.entry = readPath(r, entry);
		const target = v.field("target");
		node.os = target.field("os").text();
		node.cpu = target.field("cpu").text();
		node.abi = target.field("abi").text();
		node.optimize = intOf(v.field("optimize"));
	}
	if (node.kind == "executable") {
		const link = v.field("link");
		for (let i = 0; i < link.length(); i += 1) node.link.push(readNode(r, link.at(i)));
	}
	if (node.kind == "library") {
		node.linkage = intOf(v.field("linkage"));
		const from = optionalField(v, "from");
		if (from != null) node.from = readPath(r, from);
	}
	if (node.kind == "command") {
		const argv = v.field("argv");
		for (let i = 0; i < argv.length(); i += 1) {
			const a = argv.at(i);
			node.argv.push({ kind: intOf(a.field("kind")) as ArgKind, text: a.field("text").text(), path: readPath(r, a.field("path")) });
		}
		node.cwd = readPath(r, v.field("cwd"));
		node.inputs = readPaths(r, v.field("inputs"));
		const env = v.field("env");
		for (let i = 0; i < env.length(); i += 1) node.env.push(`${env.at(i).field("name").text()}=${env.at(i).field("value").text()}`);
		node.stdout = v.field("stdout").root.intVal != 0;
	}
	if (node.kind == "run" || node.kind == "install") node.artifact = readNode(r, v.field("artifact"));
	if (node.kind == "run") node.args = strings(v.field("args"));
	return id;
}

export function nodeById(g: BuildGraph, id: int32): GraphNode {
	for (const n of g.nodes) if (n.id == id) return n;
	throw new Error(`internal: the build graph has no node ${id}`);
}

function configureOptions(opts: CliOptions): CliOptions {
	const raiser = newCliOptions();
	raiser.command = "build";
	raiser.target = Target.Raiser;
	raiser.targetExplicit = true;
	raiser.projectRoot = opts.projectRoot;
	raiser.resolve = opts.resolve;
	seedOptionDefines(raiser);
	return raiser;
}

export function configure(buildFile: string, opts: CliOptions): Result<BuildGraph, ConfigureProblem[]> {
	const raiser = configureOptions(opts);
	setParserDefines(raiser.defines);
	defer setParserDefines(opts.defines);
	const problems: ConfigureProblem[] = [];
	setDiagnosticHook((file: string, e: ModuleError): void => {
		problems.push({ file: file == "" ? buildFile : file, line: e.line, message: e.message });
	});
	setRecoverableBuild(true);
	let compiled: RaiserModule | null = null;
	try {
		compiled = compileRaiser(buildFile, raiser, null, true);
	} catch (e) {
		if (e.message != BUILD_STOPPED) problems.push({ file: buildFile, line: 0, message: `internal: ${e.message}` });
	}
	setRecoverableBuild(false);
	setDiagnosticHook(null);
	if (compiled == null) return Result.err(problems);
	const run = runRaiser(compiled, [buildFile], (line: string): void => { console.log(line); }, false, buildFile);
	if (run.lastError != "") return Result.err([{ file: buildFile, line: 0, message: run.lastError }]);
	const r: Reader = { nodes: [], seen: [] };
	const graph: BuildGraph = { buildFile, nodes: r.nodes, exportNames: [], exportIds: [], defaultId: -1, run };
	for (const exported of compiled.exports) {
		if (exported.global < 0) continue;
		const v = live(run, run.vm!.globals[exported.global]);
		if (!isNode(v)) continue;
		graph.exportNames.push(exported.name);
		graph.exportIds.push(readNode(r, v));
	}
	const fallback = live(run, run.lastResult);
	if (isNode(fallback)) graph.defaultId = readNode(r, fallback);
	for (let i = 0; i < graph.exportNames.length; i += 1) {
		const n = nodeById(graph, graph.exportIds[i]);
		if (n.name == "") n.name = graph.exportNames[i];
	}
	return Result.ok(graph);
}
