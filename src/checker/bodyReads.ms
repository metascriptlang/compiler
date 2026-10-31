import { readDir, readFile } from "std/fs";
import { cwd } from "std/process";

let _sink: (modulePath: string) => void = (modulePath: string): void => {};
let _installed = false;

export function installBodyReadSink(sink: ((modulePath: string) => void) | null): ((modulePath: string) => void) | null {
	const outer = _installed ? _sink : null;
	_installed = sink != null;
	if (sink != null) _sink = sink;
	return outer;
}

export function recordBodyRead(modulePath: string): void {
	if (_installed && modulePath != "") _sink(modulePath);
}

interface ReaderSite {
	file: string;
	readers: int32;
	records: int32;
}

// A reader token is a primitive that hands out another module's routine body, program or context; a file
// that gains or loses one fails here until its row says how many recordBodyRead calls guard it.
const READER_TOKENS = ["routineBody(", "lookupModuleProgram(", "lookupModuleCtx(", "pickBodyCtx(", "declaringModuleCtx(", "preludeBodyCtx(", "foreignBody("];

const SITES: ReaderSite[] = [
	{ file: "checker/instantiate.ms", readers: 14, records: 2 },
	{ file: "checker/template.ms", readers: 0, records: 1 },
	{ file: "checker/checkPass.ms", readers: 4, records: 0 },
	{ file: "checker/callResolve.ms", readers: 2, records: 0 },
	{ file: "checker/ctorRoutine.ms", readers: 1, records: 0 },
	{ file: "checker/ctorDecl.ms", readers: 2, records: 0 },
	{ file: "checker/varPartitions.ms", readers: 5, records: 2 },
	{ file: "checker/effects.ms", readers: 7, records: 5 },
	{ file: "checker/sendable.ms", readers: 7, records: 1 },
	{ file: "checker/converterCycle.ms", readers: 3, records: 1 },
	{ file: "checker/importElision.ms", readers: 3, records: 0 },
	{ file: "checker/vmOnly.ms", readers: 1, records: 0 },
	{ file: "checker/orchestrator.ms", readers: 5, records: 0 },
	{ file: "compiler/meta/expand.ms", readers: 5, records: 1 },
	{ file: "compiler/meta/decorators.ms", readers: 1, records: 0 },
	{ file: "compiler/meta/stdTags.ms", readers: 1, records: 0 },
	{ file: "compiler/compile.ms", readers: 3, records: 0 },
	{ file: "compiler/transam/index.ms", readers: 7, records: 0 },
	{ file: "compiler/lsp/handlers/lifecycle.ms", readers: 3, records: 0 },
	{ file: "codegen/raiser/eval.ms", readers: 5, records: 1 },
	{ file: "transform/lowering/iterInline.ms", readers: 4, records: 1 },
	{ file: "transform/lowering/jsPointerLower.ms", readers: 2, records: 0 },
	{ file: "transform/lowering/methodDispatchLower.ms", readers: 1, records: 0 },
	{ file: "analyzer/cursors.ms", readers: 1, records: 0 },
	{ file: "analyzer/writeEffects.ms", readers: 8, records: 0 },
];

function occurrences(text: string, token: string): int32 {
	let n = 0;
	let at = text.indexOf(token, 0);
	while (at >= 0) {
		n += 1;
		at = text.indexOf(token, at + token.length);
	}
	return n;
}

function scan(root: string, dir: string, found: HashMap<string, int32[]>): void {
	for (const entry of readDir(`${root}/${dir}`)) {
		const isFolder = entry.endsWith("/");
		const name = isFolder ? entry.slice(0, entry.length - 1) : entry;
		const rel = dir == "" ? name : `${dir}/${name}`;
		if (isFolder) {
			if (rel != "test") scan(root, rel, found);
			continue;
		}
		if (!name.endsWith(".ms") || rel == "checker/bodyReads.ms") continue;
		const text = readFile(`${root}/${rel}`);
		if (!text.ok) throw new Error(`body reads: cannot read ${rel}`);
		let readers = 0;
		for (const token of READER_TOKENS) readers += occurrences(text.value, token);
		found.set(rel, [readers, occurrences(text.value, "recordBodyRead(")]);
	}
}

function surveyFailures(found: HashMap<string, int32[]>, sites: ReaderSite[]): string[] {
	const failures: string[] = [];
	const listed = new HashSet<string>();
	for (const site of sites) {
		listed.add(site.file);
		const row = found.get(site.file);
		if (row == null) failures.push(`${site.file}: listed but not found`);
		else if (row[0] != site.readers) failures.push(`${site.file}: ${row[0]} reader tokens, list says ${site.readers}; classify the new reader and call recordBodyRead where it reads another module's body`);
		else if (row[1] != site.records) failures.push(`${site.file}: ${row[1]} recordBodyRead calls, list says ${site.records}`);
	}
	for (const file of found.keys()) {
		const row = found.get(file)!;
		if (!listed.has(file) && (row[0] > 0 || row[1] > 0)) failures.push(`${file}: ${row[0]} reader tokens and ${row[1]} recordBodyRead calls, not in the list`);
	}
	return failures;
}

test "no sink makes a record a no-op" {
	recordBodyRead("/a.ms");
}

test "an installed sink receives the module and the previous sink is restored" {
	const seen: string[] = [];
	const outer = installBodyReadSink((p: string): void => { seen.push(p); });
	assert outer == null;
	recordBodyRead("/b.ms");
	recordBodyRead("");
	const inner = installBodyReadSink(null);
	assert inner != null;
	recordBodyRead("/c.ms");
	assert seen.length == 1 && seen[0] == "/b.ms";
}

test "every file that reads another module's body is listed and records it" {
	const found = new HashMap<string, int32[]>();
	scan(`${cwd()}/src`, "", found);
	const failures = surveyFailures(found, SITES);
	assert failures.length == 0, failures.join("\n");
}

test "the survey reports a reader added without a recorder" {
	const found = new HashMap<string, int32[]>();
	found.set("checker/new.ms", [1, 0]);
	found.set("checker/dropped.ms", [2, 0]);
	const failures = surveyFailures(found, [{ file: "checker/dropped.ms", readers: 2, records: 1 }]);
	assert failures.length == 2;
}
