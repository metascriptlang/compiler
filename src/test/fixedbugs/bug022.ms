// bug022 — Hub re-export of a class lost access to its static methods.
//
// Symptom:    `import { MyClass } from "./hub"; MyClass.foo();` reports
//             "Property 'foo' does not exist on type 'MyClass'". Direct
//             import from the defining module works; only the hub-mediated
//             path breaks.
// Root cause: collectPass.ms — auto-propagation of exported extension
//             methods (which is how class static dispatch resolves cross-
//             module) ran inside collectImport but NOT inside
//             collectExport's named re-export branch. A hub's own ext
//             registry stayed empty for the re-exported class's methods,
//             so downstream consumers of the hub couldn't find them.
// Fix:        Extracted `autoPropagateModuleExtensions(ctx, sourcePath,
//             markExported)` helper. Called from collectImport with
//             `markExported=false` (existing behavior). Added a second
//             call from collectExport's named re-export branch with
//             `markExported=true` so the methods flow downstream from
//             the hub.

import { compileProjectToC } from "../helpers";
import { MapEntry } from "../../module/loader";

test "bug022: hub re-export propagates class static methods" {
	const entries: MapEntry[] = [
		{ entryPath: "src/inner.ms", entrySource: `
			export class Multi {
				static one(): int32 { return 1 as int32; }
				static two(): int32 { return 2 as int32; }
			}
		` },
		{ entryPath: "src/hub.ms", entrySource: `
			export { Multi } from "./inner";
		` },
		{ entryPath: "src/main.ms", entrySource: `
			import { Multi } from "./hub";
			function main(): void {
				const a = Multi.one();
				const b = Multi.two();
				console.log("a=" + a.toString() + " b=" + b.toString());
			}
		` },
	];
	const cCode = compileProjectToC(entries, "src/main.ms");
	// Pre-fix this failed with `Property 'one' does not exist on type 'Multi'`.
	// Check both the generic ERROR sentinel AND the specific phrase to keep the
	// regression sensitive to the exact symptom.
	assert !cCode.contains("ERROR:");
	assert !cCode.contains("does not exist on type 'Multi'");
}
