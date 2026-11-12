import { cpuCount } from "std/os";
import { configure, configureCached, nodeById, BuildGraph, GraphNode, ConfigureProblem } from "./configure";
import { newExecution, executeNode, planRunsStep } from "./execute";
import { printSummary } from "./summary";
import { CliOptions } from "../options";
import { error, bold, dim, success } from "../../utils/color";
import { execFile } from "std/process";
import { msModuleExtensions } from "../../module/resolver";

export function namesGraphNode(arg: string): boolean {
	return !arg.includes("/") && !arg.includes("\\") && !msModuleExtensions.some((ext: string): boolean => arg.endsWith(ext));
}

function programArgs(extra: string[]): string[] {
	return extra.length > 0 && extra[0] == "--" ? extra.slice(1, extra.length) : extra;
}

function exportList(g: BuildGraph): string {
	return g.exportNames.length == 0 ? "no node" : g.exportNames.join(", ");
}

function describeNode(n: GraphNode): string {
	return n.description != "" ? n.description : n.kind;
}

function listNodes(g: BuildGraph): void {
	for (let i = 0; i < g.exportNames.length; i += 1) {
		const n = nodeById(g, g.exportIds[i]);
		const mark = g.exportIds[i] == g.defaultId ? " (default)" : "";
		console.log(`${bold(g.exportNames[i])}${mark}  ${dim(describeNode(n))}`);
	}
	if (g.defaultId >= 0 && !g.exportIds.includes(g.defaultId)) console.log(`${bold("default")}  ${dim(describeNode(nodeById(g, g.defaultId)))}`);
	for (const o of g.options) console.log(`-D${bold(o.name)}=…  ${dim(o.description)}`);
}

function selectNode(g: BuildGraph, name: string): int32 {
	if (name == "") {
		if (g.defaultId < 0) throw new Error(`build.ms has no default node; name one (msc build <node>) or add \`export default <node>\`; it exports ${exportList(g)}`);
		return g.defaultId;
	}
	const at = g.exportNames.indexOf(name);
	if (at < 0) throw new Error(`build.ms exports no node '${name}'; it exports ${exportList(g)}`);
	return g.exportIds[at];
}

function reportProblems(problems: ConfigureProblem[]): int32 {
	for (const p of problems) console.log(`${error("error")}: ${p.file}${p.line > 0 ? `:${p.line}` : ""}: ${p.message}`);
	return 1;
}

export function cmdBuildGraph(buildFile: string, projectRoot: string, opts: CliOptions, name: string, run: boolean): int32 {
	const configured = configureCached(buildFile, opts);
	if (!configured.ok) return reportProblems(configured.error);
	let g = configured.value;
	if (opts.listNodes) {
		listNodes(g);
		return 0;
	}
	try {
		if (g.run == null && planRunsStep(g, selectNode(g, name))) {
			const fresh = configure(buildFile, opts);
			if (!fresh.ok) return reportProblems(fresh.error);
			g = fresh.value;
		}
		const id = selectNode(g, name);
		const target = nodeById(g, id);
		if (run && target.kind != "executable" && target.kind != "command") throw new Error(`msc run takes an executable or command node; '${name}' is a ${target.kind}`);
		const passArgs = programArgs(opts.extraArgs);
		const x = newExecution(g, opts, projectRoot, opts.dryRun, passArgs, id, opts.graphJobs > 0 ? opts.graphJobs : Math.max(1, cpuCount()) as int32);
		const out = executeNode(x, id);
		if (x.reused.length > 0) console.log(dim(`reused: ${x.reused.join(", ")}`));
		if (x.dryRun) return 0;
		printSummary(x, id, opts.graphSummary);
		if (x.failures > 0) return 1;
		if (run && target.kind == "executable") return execFile(out, passArgs) as int32;
		if (out != "" && target.kind != "step") console.log(success(`Built ${bold(target.name != "" ? target.name : "default")} → ${out}`));
		return 0;
	} catch (e) {
		console.log(`${error("error")}: ${e.message}`);
		return 1;
	}
}
