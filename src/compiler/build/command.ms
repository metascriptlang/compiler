import { configure, nodeById, BuildGraph, GraphNode } from "./configure";
import { newExecution, executeNode } from "./execute";
import { CliOptions } from "../options";
import { error, bold, dim, success } from "../../utils/color";
import { execFile } from "std/process";

export function namesGraphNode(arg: string): boolean {
	return !arg.includes("/") && !arg.includes("\\") && !arg.endsWith(".ms");
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

export function cmdBuildGraph(buildFile: string, projectRoot: string, opts: CliOptions, name: string, run: boolean): int32 {
	const configured = configure(buildFile, opts);
	if (!configured.ok) {
		for (const p of configured.error) console.log(`${error("error")}: ${p.file}${p.line > 0 ? `:${p.line}` : ""}: ${p.message}`);
		return 1;
	}
	const g = configured.value;
	if (opts.listNodes) {
		listNodes(g);
		return 0;
	}
	try {
		const id = selectNode(g, name);
		const target = nodeById(g, id);
		if (run && target.kind != "executable" && target.kind != "run") throw new Error(`msc run takes an executable node; '${name}' is a ${target.kind}`);
		const passArgs = run ? programArgs(opts.extraArgs) : [];
		const x = newExecution(g, opts, projectRoot, opts.dryRun, passArgs);
		const out = executeNode(x, id);
		if (x.reused.length > 0) console.log(dim(`reused: ${x.reused.join(", ")}`));
		if (x.dryRun) return 0;
		if (run && target.kind == "executable") return execFile(out, passArgs) as int32;
		if (out != "" && target.kind != "run" && target.kind != "step") console.log(success(`Built ${bold(target.name != "" ? target.name : "default")} → ${out}`));
		return 0;
	} catch (e) {
		console.log(`${error("error")}: ${e.message}`);
		return 1;
	}
}
