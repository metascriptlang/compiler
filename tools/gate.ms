import { argv, cwd, exit } from "std/process";
import { readDir, readFile } from "std/fs";
import { JsonKind } from "std/serialize/json/types";

interface Lane {
	name: string;
	reds: string[];
	secs: number;
}

function plain(text: string): string {
	const parts = text.split("\x1b[");
	for (let i = 1; i < parts.length; i++) parts[i] = parts[i].substring(parts[i].indexOf("m") + 1);
	return parts.join("");
}

function between(line: string, head: string, tail: string): string | null {
	if (!line.startsWith(head)) return null;
	const end = line.indexOf(tail, head.length);
	return end < 0 ? null : line.substring(head.length, end);
}

function redsOf(lane: string, lines: string[]): string[] {
	const reds: string[] = [];
	const top = `${cwd()}/`;
	let file = "";
	for (const line of lines) {
		let red: string | null = null;
		if (lane == "boundary" || lane == "cache") {
			red = between(line, "FAIL  ", "  expected=");
			const setup = between(line, `${lane}: setup step failed: `, " (root ");
			if (setup != null) red = `setup: ${setup}`;
		} else if (lane == "suite" || lane == "tests") {
			if (line.startsWith("NORESULT ")) red = line.substring(9);
			else if (line.startsWith(" FAIL  ")) file = line.substring(7).startsWith(top) ? line.substring(7 + top.length) : line.substring(7);
			else if (line.startsWith("  × ")) red = `${file} > ${line.substring(4)}`;
		} else if (lane == "corpus" || lane == "san" || lane == "tsan") {
			const mark = line.indexOf("✗ FAIL ");
			const close = line.indexOf("]", mark);
			if (mark >= 0 && close > mark && line.substring(0, mark).trim() == "") red = line.substring(mark + 7, close + 1);
		} else if (lane == "guard" || lane == "hcr" || lane == "lsp") {
			red = between(line, "FAIL ", ":");
		} else if (lane == "solana") {
			red = between(line, "FAIL solana ", ":");
		} else if (lane == "tools") {
			for (const kind of [": bash -n", ": self-test", ": check"]) {
				if (line.startsWith("FAIL ") && line.endsWith(kind)) red = line.substring(5, line.length - kind.length);
			}
		} else if (lane == "build") {
			if (line.startsWith("FAIL self-host: ")) {
				const note = line.endsWith(")") ? line.lastIndexOf(" (") : line.length;
				if (note > 5) red = line.substring(5, note);
			}
		} else if (lane == "crypto") {
			const words = line.startsWith("RED ") ? line.substring(4).trim().split(" ") : [];
			if (words.length > 2) red = `${words[0]} ${words[1]}`;
		} else if (lane == "fmt") {
			for (const kind of ["LOSSY ", "UNSTABLE ", "NO-FMT ", "UNREADABLE "]) {
				const end = line.indexOf(".ms");
				if (line.startsWith(kind) && end > 0) red = line.substring(kind.length, end + 3);
			}
		}
		if (red != null && !reds.includes(red)) reds.push(red);
	}
	return reds;
}

function trailer(lines: string[], key: string): number | null {
	for (let i = lines.length - 1; i >= 0 && i >= lines.length - 6; i--) {
		if (lines[i].startsWith(`${key}=`)) return Number(lines[i].substring(key.length + 1));
	}
	return null;
}

const rerunLanes = ["corpus", "san", "tsan", "guard", "hcr", "lsp", "tests", "suite"];
const rerunCount = 3;

function linesOf(path: string): string[] | null {
	const text = readFile(path);
	return text.ok ? text.value.split("\n").filter((line: string): boolean => line != "") : null;
}

function subjectOf(lane: string, red: string): string {
	if (lane == "tests" || lane == "suite") return red.split(" > ")[0];
	const cell = red.endsWith("]") ? red.lastIndexOf(" [") : -1;
	return cell < 0 ? red : red.substring(0, cell);
}

function rerunJudges(lane: string, red: string, changed: string[]): boolean {
	if (red.endsWith("no result") || red.includes("no named failure") || red == "timed out" || red.startsWith("setup:") || red.startsWith("self-host: ")) return false;
	const subject = subjectOf(lane, red);
	return subject != "" && !changed.some((path: string): boolean => path.includes(subject));
}

function notTheSlices(red: string, onMain: string[], onSlice: string[]): string | null {
	const main = onMain.filter((name: string): boolean => name == red).length;
	const slice = onSlice.filter((name: string): boolean => name == red).length;
	if (main > 0) return `red on main ${main}/${rerunCount}`;
	return slice < 2 ? `red ${slice}/${rerunCount} on this candidate, 0/${rerunCount} on main` : null;
}

function readKnown(known: Map<string, string[]>, path: string): void {
	const text = readFile(path);
	if (!text.ok) throw new Error(`gate: cannot read ${path}`);
	const parsed = JSON.parseValue(text.value);
	if (!parsed.ok || parsed.value.kind != JsonKind.Object) throw new Error(`gate: ${path} is not a JSON object of lanes`);
	for (let i = 0; i < parsed.value.keys.length; i++) {
		const rows = parsed.value.values[i];
		if (rows.kind != JsonKind.Object) throw new Error(`gate: ${path}: lane ${parsed.value.keys[i]} is not an object of rows`);
		known.set(parsed.value.keys[i], (known.get(parsed.value.keys[i]) ?? []).concat(rows.keys));
	}
}

const params = argv.slice(1);
if (params.length < 2) {
	console.error("usage: gate <directory of lane logs> <known-red.json>...");
	exit(2);
}
const dir = params[0];
const known = new Map<string, string[]>();
for (const file of params.slice(1)) readKnown(known, file);
const lanes: Lane[] = [];
for (const entry of readDir(dir).sort()) {
	if (!entry.endsWith(".log") || entry.startsWith(".")) continue;
	const name = entry.split(".")[0];
	const text = readFile(`${dir}/${entry}`);
	if (!text.ok) throw new Error(`gate: cannot read ${dir}/${entry}`);
	const lines = plain(text.value).split("\n");
	let lane = lanes.find((l: Lane): boolean => l.name == name);
	if (lane == null) {
		lane = { name, reds: [], secs: 0 };
		lanes.push(lane);
	}
	const rc = trailer(lines, "RC");
	const secs = trailer(lines, "SECS");
	const part = entry.substring(0, entry.length - 4);
	const reds = redsOf(name, lines);
	if (lines.some((line: string): boolean => line.startsWith("TIMEOUT after "))) reds.push("timed out");
	if (rc == null || secs == null) {
		reds.push(`${part}: the log has no RC and SECS trailer`);
	} else {
		if (secs > lane.secs) lane.secs = secs;
		if (rc != 0 && reds.length == 0) reds.push(name == "build" ? "build" : name == "crypto" ? "crypto setup" : `${part}: exit ${rc} with no named failure`);
	}
	for (const red of reds) if (!lane.reds.includes(red)) lane.reds.push(red);
}
if (lanes.length == 0) throw new Error(`gate: ${dir} holds no lane log`);

const flaky = known.get("flaky") ?? [];
function steady(name: string): boolean {
	const cell = name.endsWith("]") ? name.lastIndexOf(" [") : -1;
	return !flaky.includes(name) && (cell < 0 || !flaky.includes(name.substring(0, cell)));
}
function firstThree(names: string[]): string {
	return names.slice(0, 3).join(", ");
}

const changed = linesOf(`${dir}/changed.paths`);
let anyNew = false;
for (const lane of lanes) {
	const listed = (known.get(lane.name) ?? []).filter(steady);
	const reds = lane.reds.filter(steady).sort();
	const flakes = lane.reds.filter((red: string): boolean => !steady(red)).sort();
	const fresh = reds.filter((red: string): boolean => !listed.includes(red));
	const fixed = listed.filter((row: string): boolean => !reds.includes(row)).sort();
	const onMain = rerunLanes.includes(lane.name) ? linesOf(`${dir}/${lane.name}.reruns.main`) : null;
	const onSlice = rerunLanes.includes(lane.name) ? linesOf(`${dir}/${lane.name}.reruns.slice`) : null;
	if ((onMain == null) != (onSlice == null)) throw new Error(`gate: ${lane.name} has the reruns of one side only`);
	const owed: string[] = [];
	const others: string[] = [];
	for (const red of fresh) {
		let why: string | null = null;
		if (onMain != null && onSlice != null) {
			if (changed == null) throw new Error(`gate: ${lane.name} has reruns and ${dir}/changed.paths is missing`);
			if (rerunJudges(lane.name, red, changed)) why = notTheSlices(red, onMain, onSlice);
		}
		if (why == null) owed.push(red);
		else others.push(`${red} (${why})`);
	}
	let line = `gate: ${lane.name} ${lane.secs}s · ${reds.length} red · ${reds.length - fresh.length} known · ${owed.length} new`;
	if (others.length > 0) line += ` · ${others.length} not the slice's`;
	if (fixed.length > 0) line += ` · ${fixed.length} known-now-green (${firstThree(fixed)})`;
	if (flakes.length > 0) line += ` · ${flakes.length} flaky (${firstThree(flakes)})`;
	console.log(line);
	for (const red of owed) console.log(`  new: ${red}`);
	for (const other of others) console.log(`  not the slice's: ${other}`);
	for (const row of fixed) console.log(`  known-now-green: ${row}`);
	if (owed.length > 0) anyNew = true;
}
console.log(`gate: ${anyNew ? "RED" : "GREEN"} (${lanes.map((l: Lane): string => l.name).join(", ")})`);
if (anyNew) exit(1);
