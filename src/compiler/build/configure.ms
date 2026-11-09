import { compileRaiser, runRaiser, setDiagnosticHook } from "../compile";
import { setRecoverableBuild, BUILD_STOPPED } from "../io";
import { CliOptions, Target, newCliOptions, seedOptionDefines } from "../options";
import { setParserDefines } from "../../parser/context";
import { ModuleError } from "../../module/graph";
import { RaiserModule } from "../../raiser/module";
import { RaiserContext } from "../../raiser/context";
import { RaiserValueKind } from "../../raiser/value";
import { RaiserHostValue, field, length, at, text, boxString, unboxString } from "../../raiser/marshal";
import { RaiserValue } from "../../raiser/value";
import { registerHostFn, HostCapability } from "../../raiser/hostRegistry";
import { ensureHostTableLoaded } from "../meta/hostTable";
import { MODE_RELEASE, MODE_DANGER } from "../options";
import { resolve, join, dirname } from "std/fs/path";
import { exists, readFile } from "std/fs";
import { parseJson, jsonStringify, jsonValueOf, jsonValueToStruct } from "std/serialize/json";
import { hashFile, compilerStamp } from "../cache";
import { atomicWriteFile, ensureDir } from "../io";

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
}

export interface BuildGraph {
	buildFile: string;
	nodes: GraphNode[];
	exportNames: string[];
	exportIds: int32[];
	defaultId: int32;
	options: GraphOption[];
	run: RaiserContext | null;   // null when the graph came from the configure cache
	steps: HashMap<int32, RaiserHostValue>;
}

// What the configure cache keeps: the graph without its VM, and every file the evaluation loaded.
interface CachedGraph {
	format: string;
	key: string;
	sources: string[];
	hashes: string[];
	nodes: GraphNode[];
	exportNames: string[];
	exportIds: int32[];
	defaultId: int32;
	options: GraphOption[];
}

const CONFIGURE_FORMAT = "cfg1";

export interface GraphOption {
	name: string;
	description: string;
}

let givenOptions = new HashMap<string, string>();
let declaredOptions: GraphOption[] = [];

function hostBuildOption(args: RaiserValue[]): RaiserValue {
	const name = unboxString(args[0]);
	if (!declaredOptions.some((o: GraphOption): boolean => o.name == name)) declaredOptions.push({ name, description: unboxString(args[1]) });
	const value = givenOptions.get(name);
	return boxString(value == null ? "" : `=${value}`);
}

// What the command line gives build.ms: every -Dname=value, then the flags msc already has
// for the standard options, each unless a -D names it.
function optionsGiven(opts: CliOptions): HashMap<string, string> {
	const given = new HashMap<string, string>();
	for (const o of opts.graphOptions) {
		const at = o.indexOf("=", 0);
		given.set(o.slice(0, at), o.slice(at + 1, o.length));
	}
	const defaults = newCliOptions();
	const implied = (name: string, value: string): void => { if (!given.has(name)) given.set(name, value); };
	if (opts.mode == MODE_RELEASE) implied("optimize", "ReleaseSafe");
	if (opts.mode == MODE_DANGER) implied("optimize", "ReleaseFast");
	if (opts.targetOs != defaults.targetOs) implied("os", opts.targetOs);
	if (opts.cpuTarget != defaults.cpuTarget) implied("cpu", opts.cpuTarget);
	if (opts.abi != defaults.abi) implied("abi", opts.abi);
	return given;
}

function unusedOptions(buildFile: string): ConfigureProblem[] {
	const problems: ConfigureProblem[] = [];
	const names = declaredOptions.map((o: GraphOption): string => o.name);
	for (const name of givenOptions.keys()) {
		if (names.includes(name)) continue;
		const declared = names.length == 0 ? "it declares none" : `it declares ${names.join(", ")}`;
		problems.push({ file: buildFile, line: 0, message: `the command line gives the option '${name}', which build.ms does not declare; ${declared}` });
	}
	return problems;
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
	steps: HashMap<int32, RaiserHostValue>;
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
		argv: [], cwd: null, inputs: [], env: [], stdout: false, artifact: -1, args: [],
	};
	r.nodes.push(node);
	if (node.kind == "step") r.steps.set(id, v);
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

export function configure(buildFile: string, opts: CliOptions, loaded: string[] = []): Result<BuildGraph, ConfigureProblem[]> {
	const raiser = configureOptions(opts);
	givenOptions = optionsGiven(opts);
	declaredOptions = [];
	ensureHostTableLoaded();
	registerHostFn("msBuildOption", hostBuildOption, HostCapability.Pure);
	setParserDefines(raiser.defines);
	defer setParserDefines(opts.defines);
	const problems: ConfigureProblem[] = [];
	setDiagnosticHook((file: string, e: ModuleError): void => {
		problems.push({ file: file == "" ? buildFile : file, line: e.line, message: e.message });
	});
	setRecoverableBuild(true);
	let compiled: RaiserModule | null = null;
	try {
		compiled = compileRaiser(buildFile, raiser, null, true, false, loaded);
	} catch (e) {
		if (e.message != BUILD_STOPPED) problems.push({ file: buildFile, line: 0, message: `internal: ${e.message}` });
	}
	setRecoverableBuild(false);
	setDiagnosticHook(null);
	if (compiled == null) return Result.err(problems);
	const run = runRaiser(compiled, [buildFile], (line: string): void => { console.log(line); }, false, buildFile);
	if (run.lastError != "") return Result.err([{ file: buildFile, line: 0, message: run.lastError }]);
	const unused = unusedOptions(buildFile);
	if (unused.length > 0) return Result.err(unused);
	const r: Reader = { nodes: [], seen: [], steps: new HashMap<int32, RaiserHostValue>() };
	const graph: BuildGraph = { buildFile, nodes: r.nodes, exportNames: [], exportIds: [], defaultId: -1, options: declaredOptions, run, steps: r.steps };
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

function configureKey(opts: CliOptions): string {
	const given = optionsGiven(opts);
	const names = given.keys().sort();
	let key = `${CONFIGURE_FORMAT}\n${compilerStamp()}\n`;
	for (const name of names) key = `${key}-D${name}=${given.get(name)!}\n`;
	return key;
}

function cacheFile(buildFile: string): string {
	return join(dirname(buildFile), "out/.configure.json");
}

function cachedGraph(buildFile: string, key: string): BuildGraph | null {
	const file = cacheFile(buildFile);
	if (!exists(file)) return null;
	const parsed = parseJson(try readFile(file) catch "");
	if (!parsed.ok) return null;
	const c: CachedGraph = jsonValueToStruct(parsed.value, null as CachedGraph | null);
	if (c.format != CONFIGURE_FORMAT || c.key != key || c.sources.length != c.hashes.length) return null;
	for (let i = 0; i < c.sources.length; i += 1) {
		if (hashFile(c.sources[i]) != c.hashes[i]) return null;
	}
	return { buildFile, nodes: c.nodes, exportNames: c.exportNames, exportIds: c.exportIds, defaultId: c.defaultId, options: c.options, run: null, steps: new HashMap<int32, RaiserHostValue>() };
}

function saveGraph(g: BuildGraph, key: string, loaded: string[]): void {
	const c: CachedGraph = {
		format: CONFIGURE_FORMAT, key, sources: loaded, hashes: loaded.map((p: string): string => hashFile(p)),
		nodes: g.nodes, exportNames: g.exportNames, exportIds: g.exportIds, defaultId: g.defaultId, options: g.options,
	};
	ensureDir(dirname(cacheFile(g.buildFile)));
	atomicWriteFile(cacheFile(g.buildFile), jsonStringify(c));
}

// The graph of the last configure when nothing it loaded, the compiler or the options changed;
// otherwise a fresh configure, cached unless build.ms read a file (the key would not know which).
export function configureCached(buildFile: string, opts: CliOptions): Result<BuildGraph, ConfigureProblem[]> {
	const key = configureKey(opts);
	const cached = cachedGraph(buildFile, key);
	if (cached != null) return Result.ok(cached);
	const loaded: string[] = [];
	const fresh = configure(buildFile, opts, loaded);
	if (fresh.ok && fresh.value.run!.vm!.restrictedReads == 0) saveGraph(fresh.value, key, loaded);
	return fresh;
}
