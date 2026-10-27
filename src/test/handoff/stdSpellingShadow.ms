import { compileToCWithStd, compileProjectToJSWithStd, checkProjectDiagnostics, MapEntry } from "../helpers";
import { checkSource } from "./helpers";
import { lookupSymbol, hasFlag, SymbolFlag } from "../../checker/symbol";

function one(source: string): MapEntry[] {
	return [{ entryPath: "test/main.ms", entrySource: source }];
}

function problems(entries: MapEntry[]): string[] {
	const kept: string[] = [];
	for (const m of checkProjectDiagnostics(entries, "test/main.ms")) {
		if (!m.endsWith("is declared but never used") && !m.endsWith("is imported but never used")) kept.push(m);
	}
	return kept;
}

test "std Error boxes a thrown string and types a catch binding whatever Error the module declares" {
	for (const decl of ["class Error { code: int32 = 0; }", "function Error(): int32 { return 1; }", "const Error = 3;"]) {
		const source = `${decl}\nfunction f(): void { throw "boom"; }\ntry { f(); } catch (e) { const m: string = e.message; console.log(m); }\n`;
		const found = problems(one(source));
		assert found.length == 0, decl + ": " + found.join(" | ");
		const c = compileToCWithStd(source);
		assert c.ok, decl + ": " + (c.ok ? "" : c.error);
		const js = compileProjectToJSWithStd(one(source), "test/main.ms");
		assert !js.startsWith("ERROR:"), decl + ": " + js;
	}
}

test "a thenable rejects with std Error: a user class Error does not stand in for it" {
	const thenable = (error: string) => `${error}\nclass Late { then(ok: (v: int32) => void, bad: (e: Error) => void): void { ok(1); } }\nasync function f(): Promise<int32> { return await new Late(); }\nf();\n`;
	const own = problems(one(thenable("class Error { code: int32 = 0; }")));
	assert own.length == 1 && own[0].contains("callback taking an Error"), own.join(" | ");
	const std = problems(one(thenable("")));
	assert std.length == 0, std.join(" | ");
}

test "@delegate toString reaches the std text conversion past a user String" {
	for (const decl of ["function String(x: int32): string { return \"user\"; }", "const String = 3;"]) {
		const source = `${decl}\ntype Small = distinct int8;\n@delegate function toString(this s: Small): string;\nconst s = 5 as Small;\nconsole.log(\`\${s}\`);\n`;
		const found = problems(one(source));
		assert found.length == 0, decl + ": " + found.join(" | ");
	}
}

test "new Array is decided by the bound symbol, not the spelling" {
	const user = "class Array<T> { n: int32 = 7; }\nconst a = new Array<int32>();\nconsole.log(a.n);\n";
	const found = problems(one(user));
	assert found.length == 0, found.join(" | ");
	assert compileToCWithStd(user).ok;
	const std = "const a = new Array<int32>();\na.push(1);\nconsole.log(a.length);\n";
	const control = problems(one(std));
	assert control.length == 0, control.join(" | ");
}

test "new on a function is refused, and a function named like an Arc or Locked is no cell" {
	for (const name of ["Arc", "Locked", "Foo"]) {
		const found = problems(one(`function ${name}(x: int32): int32 { return x + 1; }\nconst a = new ${name}(21);\n`));
		assert found.length == 1 && found[0].contains("is a function, not a class"), name + ": " + found.join(" | ");
	}
	const own = problems(one("class Arc { n: int32 = 3; }\nconst a = new Arc();\nconsole.log(a.n);\n"));
	assert own.length == 0, own.join(" | ");
	const cell = problems(one("const a = new Arc(5);\nconst b = new Locked(6);\n"));
	assert cell.length == 0, cell.join(" | ");
}

test "Record is std Map even when the module declares a Map" {
	const source = "class Map<K, V> { tag: int32 = 5; }\nconst r: Record<string, int32> = { a: 1 };\nconsole.log(r[\"a\"]);\n";
	const found = problems(one(source));
	assert found.length == 0, found.join(" | ");
	const c = compileToCWithStd(source);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileProjectToJSWithStd(one(source), "test/main.ms");
	assert !js.startsWith("ERROR:"), js;
}

test "a dynamic field write is judged on the receiver's own declaration, not a local type of its name" {
	const a = "export class Bag { tag: int32 = 0; }\nexport function setDynamicField(this b: Bag, key: string, v: int32): void { b.tag = v; }\n";
	const entries = (main: string): MapEntry[] => [
		{ entryPath: "test/a.ms", entrySource: a },
		{ entryPath: "test/main.ms", entrySource: main },
	];
	const shadowed = problems(entries("import { Bag as ABag, setDynamicField } from \"./a\";\nclass Bag { foo: int32 = 0; }\nconst t = new ABag();\nt.foo = 5;\nconst l = new Bag();\nl.foo = 6;\nconsole.log(l.foo);\n"));
	assert shadowed.length == 0, shadowed.join(" | ");
	const alias = problems(one("type Rec = { foo: int32 };\nfunction put(r: Rec): void { r.foo = 1; }\nput({ foo: 0 });\n"));
	assert alias.length == 0, alias.join(" | ");
}

test "an imported decorator keeps its meaning under another name" {
	const aliased = "import { delegate as fwd } from \"std/core/system\";\nstruct Account { address: uint64; lamports: uint64; }\nfunction key(this a: Account): uint64 { return a.address * 2; }\ntype Signer = distinct Account;\n@fwd function key(this s: Signer): uint64;\nconst a: Account = { address: 21, lamports: 5 };\nconsole.log((a as Signer).key());\n";
	const found = problems(one(aliased));
	assert found.length == 0, found.join(" | ");
	const ctx = checkSource("import { throws as raises } from \"std/core/system\";\n@raises function risky(): void { }\n@throws function risky2(): void { }\n");
	const viaAlias = lookupSymbol(ctx.table, "risky");
	const viaName = lookupSymbol(ctx.table, "risky2");
	assert viaAlias != null && hasFlag(viaAlias, SymbolFlag.Throws);
	assert viaName != null && hasFlag(viaName, SymbolFlag.Throws);
	const twice = checkSource("import { compilerFunc as cf } from \"std/core/system\";\n@cf\nextern function msProbeAgain(p: Ptr<void>): boolean;\n@cf\nextern function msProbeAgain(q: Ptr<void>): boolean;\n");
	let all = "";
	for (const e of twice.errors) all = all + e.message + "\n";
	assert all.contains("@compilerFunc 'msProbeAgain' is declared twice"), all;
}
