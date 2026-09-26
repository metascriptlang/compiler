// bug546 — --strict-defs and --strict-nil did nothing
//
// Symptom:    `msc check p.ms --strict-defs` on `let n: int32; if (flag) { n = 5; } return n;` and
//             `--strict-nil` on a `Foo | null` read inside a closure printed "OK no type errors".
//
// Root cause: compile.ms copied the flags onto each module's checker context after the graph check
//             had already run; the graph checker never received them. Once they arrived, the
//             strict-nil read test looked at a non-null class (TypeKind.Ref) instead of the nullable
//             union, so it warned on every class member read in std.
//
// Fix:        checkModuleGraph takes both flags and stamps the prelude context before any module is
//             checked; injectPrelude hands them to every module context. The strict-nil test fires on
//             a `T | null` reference that flow does not prove non-null.

import { checkModuleGraph, getPreludeContext } from "../../checker/orchestrator";
import { GcMode } from "../../checker/context";
import { hostTargetInfo } from "../../checker/types";
import { findModule, ErrorSeverity } from "../../module/graph";
import { MapEntry, createMapProvider, loadModuleGraph } from "../../module/loader";
import { platform } from "std/process";

function warningsOf546(source: string, strictDefs: boolean, strictNil: boolean): string[] {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/s546.ms", entrySource: source });
	const graph = loadModuleGraph("/src/s546.ms", createMapProvider(entries));
	checkModuleGraph(graph, "", ".cms", platform, hostTargetInfo(), GcMode.Orc, null, null, strictDefs, strictNil);
	const out: string[] = [];
	const mod = findModule(graph, "/src/s546.ms");
	if (mod != null) {
		for (const e of mod.errors) if (e.severity == ErrorSeverity.Warning) out.push(e.message);
	}
	const reset: MapEntry[] = [{ entryPath: "/src/r546.ms", entrySource: "const r546: int32 = 0;" }];
	checkModuleGraph(loadModuleGraph("/src/r546.ms", createMapProvider(reset)), "");
	return out;
}

function anyHas546(ws: string[], needle: string): boolean {
	for (const w of ws) if (w.indexOf(needle) >= 0) return true;
	return false;
}

const DEFS546 = "function f(flag: boolean): int32 {\n\tlet n: int32;\n\tif (flag) {\n\t\tn = 5;\n\t}\n\treturn n;\n}\n";
const NIL546 = "class Foo546 { x: int32 = 7; }\nfunction run(): int32 {\n\tlet f: Foo546 | null = new Foo546();\n\tconst g = (): int32 => f.x;\n\treturn g();\n}\n";

test "bug546: --strict-defs reaches the check of every module" {
	assert anyHas546(warningsOf546(DEFS546, true, false), "may be used before initialization");
	assert !anyHas546(warningsOf546(DEFS546, false, false), "may be used before initialization");
}

test "bug546: --strict-nil warns on a nullable class read and not on a non-null one" {
	assert anyHas546(warningsOf546(NIL546, false, true), "potentially null class 'f'");
	assert !anyHas546(warningsOf546("class Bar546 { x: int32 = 7; }\nfunction run(b: Bar546): int32 { return b.x; }\n", false, true), "potentially null");
}

test "bug546: the flags do not outlive the check that asked for them" {
	warningsOf546(DEFS546, true, true);
	const p = getPreludeContext();
	assert p != null && !p.strictDefs && !p.strictNullChecks;
}
