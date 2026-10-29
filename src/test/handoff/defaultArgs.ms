// Test: extension methods with default parameters fill missing args at call site
// When indexOf(this s: string, sub: string, start: number = 0) is called as s.indexOf("x"),
// the codegen must emit msStringIndexOf(s, "x", 0) — not msStringIndexOf(s, "x").

import { compileToC, compileProjectToC, compileProjectToJS, MapEntry } from "../helpers";
import { hasError, strictErrorCount } from "./helpers";

test "indexOf with missing start arg fills default 0" {
	const src = `
export function find(s: string): number {
	return s.indexOf("*");
}
`;
	const r = compileToC(src);
	assert r.ok;
	// Must have 3 args: msStringIndexOf(s, "*", 0)
	assert r.value.contains(", 0)");
}

test "indexOf with explicit start arg passes through" {
	const src = `
export function find(s: string): number {
	return s.indexOf("*", 5);
}
`;
	const r = compileToC(src);
	assert r.ok;
}

test "a default value is checked where it is declared, seeing only the parameters before it" {
	assert hasError("function bad(a: int32, b: string = a): string { return b; }", "'int32' is not assignable to type 'string'");
	assert hasError("function later(a: string = b, b: string = \"x\"): string { return a; }", "Undefined variable 'b'");
	assert hasError("function self(a: string = a): string { return a; }", "Undefined variable 'a'");
	assert strictErrorCount("function label(name: string, shown: string = name): string { return shown; }") == 0;
}

test "a default value that reads an earlier parameter takes the argument at the call" {
	const pre = "function label(name: string, shown: string = name): string { return name + shown; }\n"
		+ "function next(): string { return \"n\"; }\n";
	assert strictErrorCount(pre + "const a = label(\"a\"); const b = label(next()); const c = true ? label(next()) : \"\"; const f = (): string => label(next());") == 0;
	const c = compileToC(pre + "export function run(): string { return label(next()); }");
	assert c.ok, c.ok ? "" : c.error;
}

test "an argument a default value reads is bound once only where a statement can hold it" {
	const pre = "function label(name: string, shown: string = name): string { return name + shown; }\n"
		+ "function next(): string { return \"n\"; }\n";
	assert hasError(pre + "class Holder { s: string = label(next()); }", "a field initializer has no statement to bind it in");
	assert strictErrorCount(pre + "const seed = \"s\"; class Holder { s: string = label(seed); }") == 0;
	assert hasError("function bump(ref a: int32, b: int32 = a): int32 { a += b; return a; }\nconst xs: int32[] = [1];\nbump(xs[0]);", "a default value reads the ref parameter 'a', so its argument must be a variable");
}

const DFLT_LIB = "export function f(a: number, b: number = a + 1): number { return a + b; }\nexport function g(): number { return 3; }";
const DFLT_USER = "import { f, g } from \"./lib\";\nexport const u = f(g());\nexport const v = f(g());\nexport function w(): number { return f(g()) + f(g()); }";

function dfltEntries(otherFirst: boolean): MapEntry[] {
	const entries: MapEntry[] = [
		{ entryPath: "/src/lib.ms", entrySource: DFLT_LIB },
		{ entryPath: "/src/user.ms", entrySource: DFLT_USER },
		{ entryPath: "/src/other.ms", entrySource: "import { f, g } from \"./lib\";\nexport const o = f(g()) + f(g());" },
	];
	const imports = otherFirst ? "import { o } from \"./other\";\nimport { u, v, w } from \"./user\";\nconsole.log(o + u + v + w());" : "import { u, v, w } from \"./user\";\nconsole.log(u + v + w());";
	entries.push({ entryPath: "/src/main.ms", entrySource: imports });
	return entries;
}

function dfltNamesOf(code: string, moduleTag: string): string {
	const found: string[] = [];
	let at = code.indexOf("tmp");
	while (at >= 0) {
		let end = at;
		while (end < code.length) {
			const c = code.charCodeAt(end);
			const ident = c == 95 || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
			if (!ident) break;
			end += 1;
		}
		const name = code.slice(at, end);
		if (name.contains(moduleTag) && !found.includes(name)) found.push(name);
		at = code.indexOf("tmp", end);
	}
	found.sort();
	return found.join(" ");
}

test "a default-argument temp is named by its own module, whatever other module was checked first or before" {
	for (const toJs of [false, true]) {
		const emit = (otherFirst: boolean): string => toJs ? compileProjectToJS(dfltEntries(otherFirst), "/src/main.ms") : compileProjectToC(dfltEntries(otherFirst), "/src/main.ms");
		const alone = dfltNamesOf(emit(false), "userOms");
		assert alone.split(" ").length == 2, `${toJs ? "js" : "c"} module temps: ${alone}`;
		assert dfltNamesOf(emit(true), "userOms") == alone, `${toJs ? "js" : "c"} after another module: ${dfltNamesOf(emit(true), "userOms")} vs ${alone}`;
		assert dfltNamesOf(emit(false), "userOms") == alone, `${toJs ? "js" : "c"} on a second build: ${dfltNamesOf(emit(false), "userOms")} vs ${alone}`;
	}
}
