import { checkProjectDiagnostics, MapEntry } from "../helpers";

function count(entries: MapEntry[], text: string): int32 {
	let n: int32 = 0;
	for (const m of checkProjectDiagnostics(entries, "src/main.ms")) {
		if (m.indexOf(text) >= 0) n += 1;
	}
	return n;
}

function unwritten(source: string, name: string): int32 {
	return count([{ entryPath: "src/main.ms", entrySource: source }], "'" + name + "' is not assigned on every path");
}

function refused(source: string, text: string): int32 {
	return count([{ entryPath: "src/main.ms", entrySource: source }], text);
}

test "outParameterWrites: an out parameter the body never writes is an error" {
	assert unwritten("function leave(out x: int32): void { }", "x") == 1;
	assert unwritten("function leave(out s: string): void { }", "s") == 1;
	assert unwritten("function leave<T>(out x: T, v: T): void { }\nfunction f(): void { let a: int32 = 0; leave<int32>(out a, 1); }", "x") >= 1;
	assert unwritten("function leave(out x: int32, out y: int32): void { x = 1; }", "y") == 1;
}

test "outParameterWrites: an out parameter is read only after the body writes it" {
	const early = "may be read before it is assigned";
	assert refused("function f(out x: int32): void { console.log(x); x = 1; }", early) == 1;
	assert refused("function f(out x: int32): void { x += 1; }", early) == 1;
	assert refused("class K { m(out x: string): void { console.log(x); x = \"a\"; } }", early) == 1;
	assert refused("function f(out x: int32): void { x = 3; console.log(x); }", early) == 0;
	assert refused("function f(out x: int32 | null): void { console.log(x); x = 2; }", early) == 0;
}

test "outParameterWrites: a write on one path only is an error, at the end and at an early return" {
	assert unwritten("function f(out x: int32, c: boolean): void { if (c) { x = 1; } }", "x") == 1;
	assert unwritten("function f(out x: int32, c: boolean): void { if (c) { return; } x = 1; }", "x") == 1;
	assert unwritten("function f(out x: int32, n: int32): void { for (let i = 0; i < n; i++) { x = i; } }", "x") == 1;
	assert unwritten("function f(out x: int32, k: int32): void { switch (k) { case 1: x = 1; break; } }", "x") == 1;
}

test "outParameterWrites: a 'try' that returns its error leaves the parameter unwritten" {
	const lib = "function make(): Result<int32, string> { return Result.ok(1); }\n";
	assert unwritten(lib + "function f(out x: int32): Result<int32, string> { const v = try make(); x = v; return Result.ok(v); }", "x") == 1;
	assert unwritten(lib + "function f(out x: int32): Result<int32, string> { x = 0; const v = try make(); x = v; return Result.ok(v); }", "x") == 0;
}

test "outParameterWrites: a write on every path, a leaving branch or a throw is fine" {
	assert unwritten("function f(out x: int32, c: boolean): void { if (c) { x = 1; } else { x = 2; } }", "x") == 0;
	assert unwritten("function f(out x: int32, c: boolean): void { if (c) { x = 1; return; } x = 2; }", "x") == 0;
	assert unwritten("function f(out x: int32, c: boolean): void { if (c) { x = 1; return; } else { x = 2; return; } }", "x") == 0;
	assert unwritten("function f(out x: int32, c: boolean): void { if (c) { throw new Error(\"e\"); } x = 1; }", "x") == 0;
	assert unwritten("function f(out x: int32, k: int32): void { switch (k) { case 1: x = 1; break; default: x = 2; } }", "x") == 0;
	assert unwritten("function g(out y: int32): void { y = 1; }\nfunction f(out x: int32): void { g(out x); }", "x") == 0;
	assert unwritten("function g(out y: int32): void { y = 1; }\nfunction f(out x: int32): void { g(x); }", "x") == 0;
}

test "outParameterWrites: a body-less extern declaration is the trust boundary and is not checked" {
	assert refused("extern function fill(out x: int32): void from \"fill\";", "is not assigned on every path") == 0;
}

test "outParameterWrites: a local that reuses an out parameter's name is refused, because the tracking goes by name" {
	assert refused("function f(out x: int32): void { { let x: int32 = 3; console.log(x); } }", "shadows an out parameter") == 1;
	assert refused("function f(out x: int32): void { x = 1; { const y: int32 = 3; console.log(y); } }", "shadows an out parameter") == 0;
}

test "outParameterWrites: a callee that never writes a no-default type is refused where it is declared" {
	const lib = "export struct Proof { private n: int32; }\nexport function needs(p: Proof): int32 { return 1; }\n";
	const forged = "import { Proof, needs } from \"./lib\";\nfunction fake(out p: Proof): void { }\nfunction run(): int32 { let s: Proof; fake(out s); return needs(s); }\n";
	const entries: MapEntry[] = [{ entryPath: "src/lib.ms", entrySource: lib }, { entryPath: "src/main.ms", entrySource: forged }];
	assert count(entries, "'p' is not assigned on every path") == 1;
}

test "outParameterWrites: the keyword belongs to an out parameter only" {
	const fns = "function plain(x: int32): void { }\nfunction viaRef(ref x: int32): void { x = 1; }\nfunction viaOut(out x: int32): void { x = 1; }\n";
	const bad = "'out' is written only for an out parameter";
	assert refused(fns + "function f(): void { let a: int32 = 0; plain(out a); }", bad) == 1;
	assert refused(fns + "function f(): void { let a: int32 = 0; viaRef(out a); }", bad) == 1;
	assert refused(fns + "function f(): void { let a: int32 = 0; viaOut(out a); viaOut(a); viaRef(a); }", bad) == 0;
	assert refused(fns + "function f(): int32 { let a: int32; plain(out a); return a; }", "'a' may be read before it is assigned") == 1;
}

test "outParameterWrites: a callee that can throw does not assign the caller's variable across a catch" {
	const fns = "function fill(out x: int32, c: boolean): void { if (c) { throw new Error(\"e\"); } x = 1; }\n";
	const read = "'a' may be read before it is assigned";
	assert refused(fns + "function f(): int32 { let a: int32; try { fill(out a, true); } catch (e) { } return a; }", read) == 1;
	assert refused(fns + "function f(): int32 { let a: int32; try { fill(out a, false); return a; } catch (e) { return 0; } }", read) == 0;
	assert refused(fns + "function f(): int32 { let a: int32; try { fill(out a, true); } catch (e) { a = 2; } return a; }", read) == 0;
}

test "outParameterWrites: a method's out parameter is declared in its body and held to the same rule" {
	assert unwritten("class K { never(out x: int32): void { } }", "x") == 1;
	assert unwritten("class K { one(out x: int32, c: boolean): void { if (c) { x = 1; } } }", "x") == 1;
	assert unwritten("class K { good(out x: int32, c: boolean): void { if (c) { x = 1; } else { x = 2; } } }", "x") == 0;
	assert refused("class K { good(out x: int32): void { x = 1; } }", "Undefined variable") == 0;
	assert refused("class K { bump(ref x: int32): void { x += 1; } }", "Undefined variable") == 0;
}

test "outParameterWrites: a generic class's method keeps its out parameter on every instance" {
	const cls = "class G<T> { never(out x: T): void { } }\n";
	assert unwritten(cls + "function f(): void { let s: string; new G<string>().never(out s); }", "x") >= 1;
	assert unwritten("class G<T> { put(out x: T, v: T): void { x = v; } }\nfunction f(): void { let s: string; new G<string>().put(out s, \"a\"); }", "x") == 0;
}

test "outParameterWrites: a method call takes the out keyword only for an out parameter" {
	const cls = "class K { plain(x: int32): void { } fill(out x: int32): void { x = 1; } }\n";
	assert refused(cls + "function f(): void { let a: int32 = 0; new K().plain(out a); }", "'out' is written only for an out parameter") == 1;
	assert refused(cls + "function f(): int32 { let a: int32; new K().fill(out a); return a; }", "may be read before it is assigned") == 0;
}

test "outParameterWrites: a constructor parameter cannot be out or ref" {
	assert refused("class C { constructor(out x: int32) { x = 1; } }", "a constructor parameter cannot be 'out' or 'ref'") == 1;
	assert refused("class C { constructor(ref x: int32) { x = 1; } }", "a constructor parameter cannot be 'out' or 'ref'") == 1;
}
