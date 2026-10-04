import { hasError } from "./helpers";
import { compileToC, compileToJS } from "../helpers";
import { checkModuleGraph } from "../../checker/orchestrator";
import { findModule, ErrorSeverity } from "../../module/graph";
import { MapEntry, createMapProvider, loadModuleGraph } from "../../module/loader";
import { resetBuildState } from "../../compiler/buildSession";

const decls = "struct Pet { a: uint8; }\nclass Dog { n: int32 = 1; static make(): Dog { return new Dog(); } }\nenum Kind { A, B }\ninterface Shape { w: int32; }\ntype Alias = { v: int32 };\nfunction take(x: int32): int32 { return x; }\nfunction accountKind(this typeof Pet): int32 { return 4; }\n";

test "a type name in a value slot is refused before codegen" {
	const refused = [
		"const s = Pet;",
		"take(Kind);",
		"const arr = [Pet];",
		"const o = { k: Kind };",
		"function g(): Pet { return Pet; }",
		"const n = Kind + 1;",
		"const c = Pet();",
		"const t = `${Kind}`;",
		"const sh = Shape;",
		"const al = Alias;",
		"function f<T>(x: T): void { const t = T; }\nf(1 as int32);",
	];
	for (const line of refused) {
		assert hasError(decls + line, "only refers to a type, but is being used as a value here"), line;
	}
	assert hasError(decls + "const d = Dog;", "'Dog' names a class, which is not a value here");
}

test "a type name where a type is taken keeps compiling on C and JS" {
	const src = decls + "function kindOf<T>(x: T): int32 { return T.accountKind(); }\nconst ak = kindOf({ a: 1 } as Pet);\nconst a = Dog.make();\nconst k: Kind = Kind.B;\nconst u: unknown = new Dog();\nconst isDog = u instanceof Dog;\nconst size = sizeof(Pet);\nconst name = Kind[k];\n";
	const c = compileToC(src);
	assert c.ok, c.error;
	const js = compileToJS(src);
	assert js.ok, js.error;
}

function namespaceErrors(line: string): string[] {
	resetBuildState();
	const entries: MapEntry[] = [
		{ entryPath: "/src/lib.ms", entrySource: "export enum Color { Red, Green }\nexport struct Pt { x: int32; }" },
		{ entryPath: "/src/main.ms", entrySource: "import * as L from \"./lib\";\n" + line },
	];
	const graph = loadModuleGraph("/src/main.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	const mod = findModule(graph, "/src/main.ms");
	const out: string[] = [];
	if (mod == null) return ["no module"];
	for (const e of mod.errors) if (e.severity == ErrorSeverity.Error) out.push(e.message);
	return out;
}

test "a type reached through a namespace import is a type, not a value" {
	const value = namespaceErrors("const c = L.Color;");
	assert value.length == 1 && value[0].indexOf("'Color' only refers to a type") >= 0, value.join(" | ");
	assert namespaceErrors("const p = L.Pt;").length == 1;
	const member = namespaceErrors("const r = L.Color.Red;");
	assert member.length == 0, member.join(" | ");
}
