import { checkModuleGraph } from "../../checker/orchestrator";
import { findModule, ErrorSeverity } from "../../module/graph";
import { MapEntry, createMapProvider, loadModuleGraph } from "../../module/loader";
import { resetBuildState } from "../../compiler/buildSession";

const lib = "export let counter: int32 = 0;\nexport const limit: int32 = 9;\nexport function bump(): void { counter += 1; }\nexport function tally(): int32 { return counter; }";

function importErrors(main: string): string[] {
	resetBuildState();
	const entries: MapEntry[] = [
		{ entryPath: "/src/lib.ms", entrySource: lib },
		{ entryPath: "/src/main.ms", entrySource: main },
	];
	const graph = loadModuleGraph("/src/main.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/main.ms");
	const out: string[] = [];
	if (mod == null) return ["no module"];
	for (const e of mod.errors) if (e.severity == ErrorSeverity.Error) out.push(e.message);
	return out;
}

test "assigning an imported binding is refused as TypeScript refuses it" {
	for (const item of [
		{ line: "import { counter } from \"./lib\";\ncounter = 5;", name: "counter" },
		{ line: "import { counter } from \"./lib\";\ncounter += 2;", name: "counter" },
		{ line: "import { counter } from \"./lib\";\ncounter++;", name: "counter" },
		{ line: "import { counter } from \"./lib\";\n--counter;", name: "counter" },
		{ line: "import { counter as c } from \"./lib\";\nc = 5;", name: "c" },
		{ line: "import { limit } from \"./lib\";\nlimit = 5;", name: "limit" },
		{ line: "import { tally } from \"./lib\";\ntally = tally;", name: "tally" },
		{ line: "import { counter } from \"./lib\";\nlet other: int32 = 0;\n[counter, other] = [1, 2];", name: "counter" },
		{ line: "import { counter } from \"./lib\";\nfunction f(): void { counter = 1; }", name: "counter" },
	]) {
		const errors = importErrors(item.line);
		assert errors.length == 1, item.line + " => " + errors.join(" | ");
		assert errors[0] == "Cannot assign to '" + item.name + "' because it is an import.", item.line + " => " + errors[0];
	}
}

test "an imported binding is still read, and its module's own function still writes it" {
	for (const line of [
		"import { counter, bump } from \"./lib\";\nbump();\nlet seen: int32 = counter;\nseen += 1;",
		"import { tally, bump } from \"./lib\";\nbump();\nconst n: int32 = tally();",
		"import { counter } from \"./lib\";\nlet counter2: int32 = counter;\ncounter2 = 5;",
		"import { counter } from \"./lib\";\nfunction f(counter: int32): void { counter = 1; }",
	]) {
		const errors = importErrors(line);
		assert errors.length == 0, line + " => " + errors.join(" | ");
	}
}

test "a member of a namespace import is read-only" {
	for (const line of [
		"import * as L from \"./lib\";\nL.counter = 5;",
		"import * as L from \"./lib\";\nL.counter += 2;",
		"import * as L from \"./lib\";\nL.counter++;",
	]) {
		const errors = importErrors(line);
		assert errors.length == 1, line + " => " + errors.join(" | ");
		assert errors[0].indexOf("cannot assign to 'counter' because it is a read-only property") >= 0, line + " => " + errors[0];
	}
}
