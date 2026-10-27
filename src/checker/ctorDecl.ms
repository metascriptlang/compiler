import { Symbol } from "../ast/node";
import { MapEntry, createMapProvider, loadModuleGraph } from "../module/loader";
import { checkModuleGraph } from "./orchestrator";
import { lookupModuleCtx } from "./instantiate";
import { lookupLocal, symbolKey } from "./symbol";
import { ctorRoutineOf } from "./ctorRoutine";

function ctorKeyOf(user: string, className: string): string {
	const entries: MapEntry[] = [];
	entries.push({ entryPath: "/src/b.ms", entrySource: "export class P { v: number = 1; }\nexport class Cell<T> { v: number = 1; }\nexport class Q extends P { w: number = 2; }" });
	entries.push({ entryPath: "/src/a.ms", entrySource: user });
	const graph = loadModuleGraph(user == "" ? "/src/b.ms" : "/src/a.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	const owner = lookupModuleCtx("/src/b.ms");
	if (owner == null) return "b unchecked";
	const cls: Symbol | null = lookupLocal(owner.table, className);
	const routine = ctorRoutineOf(cls);
	if (routine == null) return "no routine";
	const routines: string[] = [];
	for (const name of owner.disambTable.keys()) routines.push(name);
	routines.sort();
	return `${symbolKey(routine)} ${routine.itemModule == owner.itemModule ? "owner" : "importer"} ${routines.join(",")}`;
}

function usersOf(name: string): string {
	return `import { ${name} } from "./b";\nexport const x = new ${name}${name == "Cell" ? "<int32>" : ""}().v;`;
}

test "a class without a written constructor owns its routine after its own check" {
	assert ctorKeyOf("", "P").startsWith("P_init.0./src/b.ms owner "), ctorKeyOf("", "P");
}

test "a user's new reaches the routine its class's own check minted" {
	assert ctorKeyOf(usersOf("P"), "P") == ctorKeyOf("", "P"), `${ctorKeyOf(usersOf("P"), "P")} vs ${ctorKeyOf("", "P")}`;
}

test "a generic class and a subclass of a class without a constructor do the same" {
	for (const name of ["Cell", "Q"]) {
		assert ctorKeyOf("", name).startsWith(`${name}_init.0./src/b.ms owner `), ctorKeyOf("", name);
		assert ctorKeyOf(usersOf(name), name) == ctorKeyOf("", name), `${name}: ${ctorKeyOf(usersOf(name), name)} vs ${ctorKeyOf("", name)}`;
	}
}
