// E2E: Closures and Arrow Functions → C output
// Tests lambda lifting transform + closure codegen.

import { compileToC } from "../helpers";

// Closures work end-to-end — see bug021_*.ms for the parser-side regression
// coverage; the lambda-lifting + codegen path is exercised by these E2E tests.

test "E2E C: non-capturing arrow function" {
	const src = "const double = (n: number): number => n * 2;\nconst r = double(5);";
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: closure captures outer variable" {
	const src = "function outer(): number {\n  const x: number = 10;\n  const f = (): number => x + 1;\n  return f();\n}\nconst r = outer();";
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: closure with mutable capture" {
	const src = "function make(): number {\n  let n: number = 0;\n  const inc = (): number => { n = n + 1; return n; };\n  return inc();\n}\nconst r = make();";
	const c = compileToC(src);
	assert c.ok;
}

test "E2E C: a lifted env, a loop temp and two same-named block locals each reach the frame with their own item" {
	const src = `function f(n: int32): int32 {
	let total = 0;
	{ const x = n; total += x; }
	{ const x = n * 2; total += x; }
	for (const v of [n, n + 1]) total += v;
	const g = (k: int32): int32 => total + k + n;
	return g(1);
}
console.log(f(3));`;
	const c = compileToC(src);
	assert c.ok, c.ok ? "" : c.error;
}

test "E2E C: an arity adapter's parameters reach the frame with their own item" {
	const src = `function one(s: string): string { return s + "!"; }
function apply(f: (s: string, i: int32) => string): string { return f("a", 1); }
console.log(apply(one));`;
	const c = compileToC(src);
	assert c.ok, c.ok ? "" : c.error;
}

test "E2E C: a union text helper's parameter reaches the frame with its own item" {
	const src = `function show(v: int32 | string): string { return \`\${v}\`; }
console.log(show(1));`;
	const c = compileToC(src);
	assert c.ok, c.ok ? "" : c.error;
}

const UP_CHAIN = (okBody: string) => `class Item { v: int32 = 0; next: Item | null = null; }
function outer(items: Item[]): int32 {
	const run = (): int32 => {
		const best = items[0];
		const ok = (x: Item): boolean => ${okBody};
		let n: int32 = 0;
		for (const x of items) if (ok(x)) n += 1;
		return n;
	};
	return run();
}
const items: Item[] = [new Item(), new Item()];
console.log(outer(items));`;

function envStruct(c: string, owner: string): string {
	for (const line of c.split("\n")) {
		if (line.startsWith(`struct dollarEnv_${owner}`) && line.endsWith(" {")) {
			const open = c.indexOf(line, 0);
			return c.slice(open, c.indexOf("};", open));
		}
	}
	return `<no env ${owner}>`;
}

test "E2E C: a closure env whose nested closure reads only its own frame has no $up" {
	const c = compileToC(UP_CHAIN("x.v >= best.v"));
	assert c.ok, c.ok ? "" : c.error;
	const env = envStruct(c.ok ? c.value : "", "outer_arrow");
	assert env.contains("best"), env;
	assert !env.contains("dollarup_"), env;
}

test "E2E C: a closure env whose nested closure reads an ancestor binding keeps its $up" {
	const c = compileToC(UP_CHAIN("x.v >= best.v && items.length > 1"));
	assert c.ok, c.ok ? "" : c.error;
	const env = envStruct(c.ok ? c.value : "", "outer_arrow");
	assert env.contains("best"), env;
	assert env.contains("dollarup_"), env;
}

const NATIVE_LATER = (decl: string) => `class Runner { ${decl} }
function outer(next: string): void {
	const t = (): void => { Runner.later((): int32 => next.length); };
	t();
}
outer("x");`;

function envTypeInfo(c: string, owner: string): string {
	for (const line of c.split("\n")) {
		if (line.startsWith(`msTypeInfo dollarEnv_${owner}`)) return line;
	}
	return `<no type info ${owner}>`;
}

test "E2E C: a closure env whose closure goes to a native method holds the enclosing env counted" {
	const c = compileToC(NATIVE_LATER(`static extern later(cb: () => int32): void from "runLater";`));
	assert c.ok, c.ok ? "" : c.error;
	const info = envTypeInfo(c.ok ? c.value : "", "outer_arrow");
	assert info.contains(".destroyFn = dollarEnv_outer_arrow"), info;
}

test "E2E C: a closure env whose closure goes to a native method named by its own name holds the enclosing env counted" {
	const c = compileToC(NATIVE_LATER("static extern later(cb: () => int32): void;"));
	assert c.ok, c.ok ? "" : c.error;
	const info = envTypeInfo(c.ok ? c.value : "", "outer_arrow");
	assert info.contains(".destroyFn = dollarEnv_outer_arrow"), info;
}
