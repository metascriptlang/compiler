import { compileProjectToCWithStd, compileProjectToJSWithStd, checkProjectDiagnostics, MapEntry } from "../helpers";

function twoModules(a: string, b: string, main: string): MapEntry[] {
	return [
		{ entryPath: "test/a.ms", entrySource: a },
		{ entryPath: "test/b.ms", entrySource: b },
		{ entryPath: "test/main.ms", entrySource: main },
	];
}

function problems(entries: MapEntry[]): string[] {
	const kept: string[] = [];
	for (const m of checkProjectDiagnostics(entries, "test/main.ms")) {
		if (!m.endsWith("is declared but never used") && !m.endsWith("is imported but never used")) kept.push(m);
	}
	return kept;
}

test "new builds the expected type only when the callee is that declaration, not a same-spelled one" {
	const a = "export struct Point { x: int32; y: int32; }\nexport struct Box<T> { v: T; n: int32; }\n";
	const shadowed = problems(twoModules(a, "",
		"import { Point as APoint } from \"./a\";\nstruct Point { y: int32; x: int32; label: string; }\nconst p: APoint = new Point(1, 2);\nconsole.log(p.x);\n"));
	assert shadowed.length > 0, "a local Point must not be built as the imported APoint";
	const generic = problems(twoModules(a, "",
		"import { Box as ABox } from \"./a\";\nstruct Box<T> { n: int32; v: T; }\nconst b: ABox<int32> = new Box<int32>(1, 2);\nconsole.log(b.v);\n"));
	assert generic.length > 0, "a local Box<T> must not be built as the imported ABox<T>";
	const same = problems(twoModules(a, "",
		"import { Point as APoint } from \"./a\";\nconst p: APoint = new APoint(1, 2);\nconsole.log(p.x);\n"));
	assert same.length == 0, same.join(" | ");
}

test "a struct argument takes the union slot of its own declaration when two modules declare the same struct name" {
	const decl = "export struct P { x: int32; }\n";
	for (const order of ["PA | PB", "PB | PA"]) {
		const main = `import { P as PA } from "./a";\nimport { P as PB } from "./b";\ntype U = ${order};\nfunction show(u: U): string { return "ok"; }\nconst pa: PA = { x: 1 };\nconst pb: PB = { x: 2 };\nconsole.log(show(pa));\nconsole.log(show(pb));\n`;
		const entries = twoModules(decl, decl, main);
		const c = compileProjectToCWithStd(entries, "test/main.ms");
		assert !c.startsWith("ERROR:"), order + ": " + c;
		assert c.indexOf("._tag=0, .v0=", 0) >= 0 && c.indexOf("._tag=1, .v1=", 0) >= 0, order + ": the two arguments share one slot";
		const js = compileProjectToJSWithStd(entries, "test/main.ms");
		assert !js.startsWith("ERROR:"), order + ": " + js;
	}
	const classes = "export class P { x: int32 = 0; }\n";
	const viaClass = "import { P as PA } from \"./a\";\nimport { P as PB } from \"./b\";\ntype U = PA | PB;\nfunction show(u: U): string { return \"ok\"; }\nconsole.log(show(new PA()));\nconsole.log(show(new PB()));\n";
	const cc = compileProjectToCWithStd(twoModules(classes, classes, viaClass), "test/main.ms");
	assert !cc.startsWith("ERROR:"), cc;
	assert cc.indexOf("._tag=0, .v0=", 0) >= 0 && cc.indexOf("._tag=1, .v1=", 0) >= 0, "class twins take distinct slots";
}

function sameSpellingBothSides(message: string): boolean {
	const got = message.indexOf("got ", 0);
	const expected = message.indexOf(", expected ", 0);
	if (got < 0 || expected < got) return false;
	return message.slice(got + 4, expected) == message.slice(expected + 11, message.length);
}

test "type arguments are bound from a generic instance only of the same declaration" {
	const a = "export interface Pair<A, B> { first: A; second: B; }\nexport function second<A, B>(p: Pair<A, B>): B { return p.second; }\nexport function mk(): Pair<string, int32> { return { first: \"s\", second: 42 }; }\n";
	for (const local of ["interface Pair<B, A> { second: B; first: A; }", "interface Pair<A, B> { first: A; second: B; }"]) {
		const main = `import { second } from "./a";\n${local}\nconst lp: Pair<int32, string> = { second: 1, first: "x" };\nconsole.log(second(lp));\n`;
		const found = problems(twoModules(a, "", main));
		assert found.length > 0, local + ": a local Pair is not the imported Pair";
		for (const m of found) assert !sameSpellingBothSides(m), local + ": " + m;
	}
	const own = problems(twoModules(a, "", "import { second, mk } from \"./a\";\nconsole.log(second(mk()));\n"));
	assert own.length == 0, own.join(" | ");
}
