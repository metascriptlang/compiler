import { checkModuleGraph } from "../../checker/orchestrator";
import { findModule, ErrorSeverity } from "../../module/graph";
import { MapEntry, createMapProvider, loadModuleGraph } from "../../module/loader";
import { resetBuildState } from "../../compiler/buildSession";

function checkErrors(source: string): string[] {
	resetBuildState();
	const entries: MapEntry[] = [{ entryPath: "/src/main.ms", entrySource: source }];
	const graph = loadModuleGraph("/src/main.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/main.ms");
	const out: string[] = [];
	if (mod == null) return ["no module"];
	for (const e of mod.errors) if (e.severity == ErrorSeverity.Error) out.push(e.message);
	return out;
}

test "an extern var or extern let is assigned and updated like the binding it declares" {
	for (const source of [
		"extern var errno: int32;\nerrno = 0;",
		"extern var errno: int32;\nerrno += 1;\nerrno++;",
		"extern let nativeError: int32 from \"errno\";\nnativeError = 0;",
		"extern let nativeError: int32 from \"errno\";\nfunction clear(): void { nativeError = 0; --nativeError; }",
	]) {
		const errors = checkErrors(source);
		assert errors.length == 0, source + " => " + errors.join(" | ");
	}
}

test "an extern const stays read-only" {
	for (const source of [
		"extern const EOF: int32;\nEOF = 0;",
		"extern const EOF: int32;\nEOF += 1;",
		"extern const EOF: int32;\nfunction f(): void { EOF++; }",
	]) {
		const errors = checkErrors(source);
		assert errors.length == 1, source + " => " + errors.join(" | ");
		assert errors[0].contains("'EOF' is const"), source + " => " + errors[0];
	}
}
