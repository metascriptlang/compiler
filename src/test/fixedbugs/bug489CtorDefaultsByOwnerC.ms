// bug489 — two modules with a same-named class shared one constructor signature
//
// Symptom:    a.ms `class Node { constructor(v: int32 = 7) }`, b.ms `class Node { constructor(n:
//             string = "d") }`: C declared b's `Node_init` a second time with a's `int32_t`
//             parameter (conflicting types), and `new Node()` in b took a's default 7 on JS.
// Root cause: the constructor registry that carries a class's signature and defaults past
//             ctorLower was keyed by the bare `<Class>_new`, and the checker's default fill and
//             codegen's `_init` prototype looked it up by that bare name.
// Fix:        registration and every lookup key the class by its owner-qualified name
//             (monoBaseName, the spelling generic instances already use).

import { compileProjectToC, compileProjectToJS, MapEntry } from "../helpers";

const A = "class Node {\n\tv: int32;\n\tconstructor(v: int32 = 7) { this.v = v; }\n}\nclass Base {\n\tn: int32;\n\tconstructor(n: int32) { this.n = n; }\n}\nclass Kid extends Base {\n\tconstructor() { super(40); }\n}\nexport function makeA(): int32 { return new Node().v + new Kid().n + new Base(1).n; }\n";
const B = "class Node {\n\tname: string;\n\tconstructor(n: string = \"d\") { this.name = n; }\n}\nclass Base {\n\ts: string;\n\tconstructor(s: string) { this.s = s; }\n}\nclass Kid extends Base {\n\tconstructor() { super(\"k\"); }\n}\nexport function makeB(): string { return new Node().name + new Kid().s + new Base(\"x\").s; }\n";
const MAIN = "import { makeA } from \"./a\";\nimport { makeB } from \"./b\";\nconsole.log(makeA(), makeB());\n";

function entries(): MapEntry[] {
	return [
		{ entryPath: "bug489/a.ms", entrySource: A },
		{ entryPath: "bug489/b.ms", entrySource: B },
		{ entryPath: "bug489/main.ms", entrySource: MAIN },
	];
}

function initPrototypes(c: string, cls: string, module: string): string[] {
	const found: string[] = [];
	let at = c.indexOf(`void ${cls}__`, 0);
	while (at >= 0) {
		const eol = c.indexOf("\n", at);
		const line = c.slice(at, eol > 0 ? eol : c.byteLength);
		if (line.contains(`${module}Oms_init(`) && line.endsWith(";")) found.push(line);
		at = c.indexOf(`void ${cls}__`, at + 1);
	}
	return found;
}

test "bug489: b's Node_init is declared only with b's parameter type" {
	const c = compileProjectToC(entries(), "bug489/main.ms");
	assert !c.startsWith("ERROR:");
	const protos = initPrototypes(c, "Node", "bug489Zb");
	assert protos.length > 0;
	for (const p of protos) assert !p.contains("int32_t");
}

test "bug489: a super call reaches b's Base_init with b's parameter type" {
	const c = compileProjectToC(entries(), "bug489/main.ms");
	const protos = initPrototypes(c, "Base", "bug489Zb");
	assert protos.length > 0;
	for (const p of protos) assert !p.contains("int32_t");
}

function jsFnBody(js: string, name: string): string {
	const at = js.indexOf(`function ${name}(`, 0);
	if (at < 0) return "";
	const end = js.indexOf("\n}\n", at);
	return js.slice(at, end > 0 ? end : js.byteLength);
}

test "bug489: new Node() in b takes b's default on JS" {
	const js = compileProjectToJS(entries(), "bug489/main.ms");
	assert !js.startsWith("ERROR:");
	const body = jsFnBody(js, "makeB");
	assert body.contains("Oms(\"d\")");
	assert !body.contains("Oms(7)");
}
