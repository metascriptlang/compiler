import { Execution, NodeState, NodeResult, label } from "./execute";
import { GraphNode, nodeById } from "./configure";
import { SummaryMode } from "../options";
import { bold, cyan, dim, green, red, colorEnabled } from "../../utils/color";

function span(ms: number): string {
	if (ms >= 60000) return `${Math.floor(ms / 60000)}m`;
	if (ms >= 1000) return `${Math.floor(ms / 1000)}s`;
	return `${Math.floor(ms)}ms`;
}

function peak(bytes: number): string {
	if (bytes >= 1e9) return `${Math.floor(bytes / 1e9)}G`;
	if (bytes >= 1e6) return `${Math.floor(bytes / 1e6)}M`;
	if (bytes >= 1e3) return `${Math.floor(bytes / 1e3)}K`;
	return `${bytes}B`;
}

function finished(word: string, r: NodeResult): string {
	return `${green(word)}${dim(` ${span(r.ms)}${r.peakRss > 0 ? ` MaxRSS:${peak(r.peakRss)}` : ""}`)}`;
}

function status(r: NodeResult): string {
	return match (r.state) {
		NodeState.Success => finished(" success", r),
		NodeState.Reused => finished(" reused", r),
		NodeState.Failure => red(" failure"),
		NodeState.DependencyFailure => dim(" transitive failure"),
	};
}

function hidden(mode: SummaryMode, state: NodeState): boolean {
	return match (mode) {
		SummaryMode.New => state == NodeState.Reused,
		SummaryMode.Failures => state == NodeState.Success || state == NodeState.Reused,
		_ => false,
	};
}

function tree(x: Execution, n: GraphNode, mode: SummaryMode, indent: string, depth: int32, last: boolean, unseen: HashSet<int32>, lines: string[]): void {
	const first = unseen.has(n.id);
	unseen.delete(n.id);
	const r = x.results.get(n.id)!;
	if (hidden(mode, r.state)) return;
	const drawn = colorEnabled();
	const branch = depth == 0 ? "" : !drawn ? "+- " : last ? "└─ " : "├─ ";
	const line = `${indent}${branch}${label(n)}`;
	if (!first) {
		lines.push(dim(`${line}${n.deps.length == 0 ? " (shown above)" : ` (+${n.deps.length} more dependencies shown above)`}`));
		return;
	}
	lines.push(`${line}${status(r)}`);
	let lastShown = n.deps.length - 1;
	for (let i = n.deps.length - 1; i >= 0 && mode != SummaryMode.All; i -= 1) {
		if (hidden(mode, x.results.get(n.deps[i])!.state)) continue;
		lastShown = i;
		break;
	}
	const below = depth == 0 ? indent : `${indent}${last ? "   " : drawn ? "│  " : "|  "}`;
	for (let i = 0; i < n.deps.length; i += 1) tree(x, nodeById(x.graph, n.deps[i]), mode, below, depth + 1, i == lastShown, unseen, lines);
}

export function printSummary(x: Execution, id: int32, mode: SummaryMode): void {
	if (mode == SummaryMode.None || (mode == SummaryMode.Failures && x.failures == 0)) return;
	console.log(`${bold(cyan("Build Summary:"))} ${x.succeeded}/${x.results.size} steps succeeded${x.failures > 0 ? dim(` (${x.failures} failed)`) : ""}`);
	if (mode == SummaryMode.Line) return;
	const unseen = new HashSet<int32>();
	for (const key of x.results.keys()) unseen.add(key);
	const lines: string[] = [];
	tree(x, nodeById(x.graph, id), mode, "", 0, true, unseen, lines);
	console.log(lines.join("\n"));
}
