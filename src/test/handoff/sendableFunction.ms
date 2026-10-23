import { hasError, strictErrorCount } from "./helpers";

const HANDLER = `
type Handler = (n: int32) => int32;
function twice(n: int32): int32 { return n * 2; }
function run(h: Sendable<Handler>, n: int32): int32 { return h(n); }
`;

test "sendableFunction: a function declaration and a closure over constants convert to Sendable<F>" {
	const accepted = [
		{ name: "a module function as an argument", source: HANDLER + "const r = run(twice, 1);" },
		{ name: "a module function stored", source: HANDLER + "const h: Sendable<Handler> = twice;" },
		{
			name: "a closure over a const",
			source: HANDLER + "const base: int32 = 10;\nconst r = run((n: int32): int32 => n + base, 2);",
		},
		{
			name: "a nested declaration over a const",
			source: HANDLER + "function f(): int32 {\n\tconst k: int32 = 3;\n" +
				"\tfunction add(n: int32): int32 { return n + k; }\n\treturn run(add, 1);\n}",
		},
	];
	for (const row of accepted) {
		assert strictErrorCount(row.source) == 0, row.name;
	}
}

test "sendableFunction: a closure capturing mutable state is refused, naming the capture" {
	const mutableLocal = HANDLER + "function f(): int32 {\n\tlet counter: int32 = 0;\n" +
		"\treturn run((n: int32): int32 => { counter = counter + n; return counter; }, 1);\n}";
	assert hasError(mutableLocal, "mutable variable 'counter' cannot be captured by a Sendable function");
	const nestedDeclaration = HANDLER + "function f(): int32 {\n\tlet total: int32 = 0;\n" +
		"\tfunction add(n: int32): int32 { total = total + n; return total; }\n\treturn run(add, 1);\n}";
	assert hasError(nestedDeclaration, "mutable variable 'total' cannot be captured by a Sendable function");
	const shadowedAtCall = HANDLER + "function f(): int32 {\n\tlet total: int32 = 0;\n" +
		"\tconst add = (n: int32): int32 => { total = total + n; return total; };\n" +
		"\tif (true) {\n\t\tconst total: int32 = 5;\n\t\treturn run(add, total);\n\t}\n\treturn 0;\n}";
	assert hasError(shadowedAtCall, "mutable variable 'total' cannot be captured by a Sendable function");
	const classInstance = HANDLER + "class Counter { n: int32 = 0; }\nconst c = new Counter();\n" +
		"const r = run((n: int32): int32 => { c.n = c.n + n; return c.n; }, 1);";
	assert hasError(classInstance, "cannot write through Readonly<Counter>");
}

test "sendableFunction: a plain function value does not convert, by argument, assignment or field" {
	const refused = [
		{ name: "an argument", source: HANDLER + "function f(h: Handler): int32 { return run(h, 1); }" },
		{ name: "a declaration", source: HANDLER + "function f(h: Handler): void { const s: Sendable<Handler> = h; }" },
		{
			name: "a field store",
			source: HANDLER + "interface Server { handler: Sendable<Handler>; }\n" +
				"function f(s: Server, h: Handler): void { s.handler = h; }",
		},
	];
	for (const row of refused) {
		assert hasError(row.source, "'h' is a plain function value"), row.name;
	}
}

test "sendableFunction: Sendable<F> takes only a function type and widens to F" {
	assert hasError("const n: Sendable<number> = 1;", "Sendable<F> takes a function type, got 'number'");
	const widened = HANDLER + "const kept: Sendable<Handler> = twice;\nconst plain: Handler = kept;\nconst r = plain(3);";
	assert strictErrorCount(widened) == 0;
}

test "sendableFunction: a Sendable<F> crosses spawn and actor calls where a plain F stops at the actor" {
	const spawned = HANDLER + "async function f(): Promise<int32> {\n" +
		"\tconst h: Sendable<Handler> = twice;\n\tconst n: int32 = 2;\n\treturn await spawn(() => h(n));\n}";
	assert strictErrorCount(spawned) == 0;
	const ACTOR = HANDLER + "actor Worker {\n" +
		"\tapply(h: Sendable<Handler>, n: int32): int32 { return h(n); }\n" +
		"\tapplyPlain(h: Handler, n: int32): int32 { return h(n); }\n}\n";
	const sendableArg = ACTOR + "async function f(w: Worker): Promise<int32> { return await w.apply(twice, 4); }";
	assert strictErrorCount(sendableArg) == 0;
	const plainArg = ACTOR + "async function f(w: Worker): Promise<int32> {\n" +
		"\tconst h: Handler = twice;\n\treturn await w.applyPlain(h, 4);\n}";
	assert hasError(plainArg, "take a Sendable<F> instead");
}

test "sendableFunction: code that may run on another thread is refused when it reaches mutable module state" {
	const bump = "let hits: int32 = 0;\nfunction bump(): int32 { hits = hits + 1; return hits; }\n";
	const spawned = bump + "async function f(): Promise<int32> { return await spawn(() => bump()); }";
	assert hasError(spawned, "spawn runs this thunk on another thread, but it calls 'bump'") && strictErrorCount(spawned) > 0;
	const sendable = HANDLER + bump + "const r = run((n: int32): int32 => n + bump(), 1);";
	assert hasError(sendable, "a Sendable function may run on another thread, but it calls 'bump'") && strictErrorCount(sendable) > 0;
	const sendableDecl = HANDLER + bump + "function addHits(n: int32): int32 { return n + bump(); }\nconst r = run(addHits, 1);";
	assert hasError(sendableDecl, "a Sendable function may run on another thread, but it calls 'bump'") && strictErrorCount(sendableDecl) > 0;
}

test "sendableFunction: a const scalar or a Locked<T> module binding reaches another thread without an error" {
	const shared = "const LIMIT: int32 = 3;\nconst cell: Locked<int32> = new Locked<int32>(0);\n" +
		"function peek(c: Locked<int32>): int32 { return LIMIT; }\n";
	const spawned = shared + "async function f(): Promise<int32> { return await spawn(() => peek(cell) + LIMIT); }";
	assert strictErrorCount(spawned) == strictErrorCount(shared), "spawn over a const scalar and a Locked<T>";
	const reads = "async function f(): Promise<void> { const p = await spawn(() => at); console.log(p[]); }";
	const pointed = "const name = \"global\";\nconst at = name as Ptr<string>;\n";
	assert strictErrorCount(pointed + reads) == strictErrorCount(pointed), "spawn over a const pointer to a const string";
	const mutablePointed = "let name = \"global\";\nconst at = name as Ptr<string>;\n" + reads;
	assert hasError(mutablePointed, "uses module-level 'at'") && strictErrorCount(mutablePointed) > 0, "a const pointer to a mutable string";
}

test "sendableFunction: a callback a routine calls is judged where it is passed" {
	const HELPERS = "import { lockedUpdate } from \"std/core/promise\";\nlet hits: int32 = 0;\n" +
		"const cell: Locked<int32> = new Locked<int32>(0);\n" +
		"function apply(f: (v: int32) => int32, v: int32): int32 { return f(v); }\n" +
		"function forward(g: (v: int32) => int32, v: int32): int32 { return apply(g, v) + 1; }\n";
	const quiet = [
		{ name: "a pure callback to lockedUpdate", body: "lockedUpdate(cell, (v: int32): int32 => v + 1); return 0;" },
		{ name: "a pure callback to a helper", body: "return apply((v: int32): int32 => v * 2, 1);" },
		{ name: "a pure callback forwarded twice", body: "return forward((v: int32): int32 => v * 2, 1);" },
		{ name: "a pure const-bound closure called", body: "const inner = (v: int32): int32 => v * 2; return inner(1);" },
		{ name: "a const-bound closure calling itself", body: "const down = (v: int32): int32 => v > 0 ? down(v - 1) : 0; return down(3);" },
	];
	for (const row of quiet) {
		const source = HELPERS + "async function f(): Promise<int32> { return await spawn(() => { " + row.body + " }); }";
		assert strictErrorCount(source) == strictErrorCount(HELPERS), row.name;
	}
	const writes = "(v: int32): int32 => { hits = hits + 1; return v; }";
	const warned = [
		{ name: "a writing callback to lockedUpdate", body: "lockedUpdate(cell, " + writes + "); return 0;" },
		{ name: "a writing callback to a helper", body: "return apply(" + writes + ", 1);" },
		{ name: "a writing callback forwarded twice", body: "return forward(" + writes + ", 1);" },
		{ name: "a writing const-bound closure called", body: "const inner = " + writes + "; return inner(1);" },
	];
	for (const row of warned) {
		const source = HELPERS + "async function f(): Promise<int32> { return await spawn(() => { " + row.body + " }); }";
		assert hasError(source, "uses module-level 'hits'") && strictErrorCount(source) > 0, row.name;
	}
	const escaped = HELPERS + "function later(f: (v: int32) => int32): () => int32 { return (): int32 => f(1); }\n" +
		"async function g(): Promise<int32> { return await spawn(() => later((v: int32): int32 => v)()); }";
	assert hasError(escaped, "calls a function value") && strictErrorCount(escaped) > 0, "a callback called from a closure it escapes into";
	const opaque = HELPERS + "function pick(): (v: int32) => int32 { return (v: int32): int32 => v; }\n" +
		"async function g(): Promise<int32> { const h = pick(); return await spawn(() => apply(h, 1)); }";
	assert hasError(opaque, "passes a function value") && strictErrorCount(opaque) > 0, "a function value whose body is not visible";
}
