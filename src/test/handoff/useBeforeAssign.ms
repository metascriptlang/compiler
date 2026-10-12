import { checkProjectDiagnostics, MapEntry } from "../helpers";

function unassignedReads(source: string, name: string): int32 {
	const entries: MapEntry[] = [{ entryPath: "src/main.ms", entrySource: source }];
	let n: int32 = 0;
	for (const m of checkProjectDiagnostics(entries, "src/main.ms")) {
		if (m.indexOf("'" + name + "' may be read before it is assigned") >= 0) n += 1;
	}
	return n;
}

test "useBeforeAssign: a scalar local read before any assignment is an error" {
	assert unassignedReads("function f(): int32 { let n: int32; return n; }", "n") == 1;
	assert unassignedReads("function f(): string { let s: string; return s; }", "s") == 1;
	assert unassignedReads("function f(): boolean { let b: boolean; return b; }", "b") == 1;
}

test "useBeforeAssign: an assignment on one branch only leaves the read an error" {
	assert unassignedReads("function f(c: boolean): int32 { let n: int32; if (c) { n = 1; } return n; }", "n") == 1;
	assert unassignedReads("function f(k: int32): int32 { let n: int32; switch (k) { case 1: n = 1; break; } return n; }", "n") == 1;
	assert unassignedReads("function f(): int32 { let n: int32; try { n = 1; } catch (e) { } return n; }", "n") == 1;
}

test "useBeforeAssign: an assignment on every path, or a branch that leaves, makes the read fine" {
	assert unassignedReads("function f(c: boolean): int32 { let n: int32; if (c) { n = 1; } else { n = 2; } return n; }", "n") == 0;
	assert unassignedReads("function f(c: boolean): int32 { let n: int32; if (c) { return 0; } else { n = 2; } return n; }", "n") == 0;
	assert unassignedReads("function f(k: int32): int32 { let n: int32; switch (k) { case 1: n = 1; break; default: n = 2; } return n; }", "n") == 0;
	assert unassignedReads("function f(): int32 { let n: int32; try { n = 1; } catch (e) { n = 2; } return n; }", "n") == 0;
	assert unassignedReads("function f(): int32 { let n: int32; while (true) { n = 1; break; } return n; }", "n") == 0;
}

test "useBeforeAssign: an assignment inside a loop body does not make the read after the loop fine" {
	assert unassignedReads("function f(m: int32): int32 { let n: int32; for (let i = 0; i < m; i++) { n = i; } return n; }", "n") == 1;
	assert unassignedReads("function f(xs: int32[]): int32 { let n: int32; for (const x of xs) { n = x; } return n; }", "n") == 1;
}

test "useBeforeAssign: a local whose type admits null reads fine and holds null" {
	assert unassignedReads("function f(): int32 | null { let n: int32 | null; return n; }", "n") == 0;
	assert unassignedReads("class Box { v: int32 = 1; } function f(): Box | null { let b: Box | null; return b; }", "b") == 0;
	assert unassignedReads("function f(): string | null { let s: string | null; return s; }", "s") == 0;
}

test "useBeforeAssign: an out argument assigns the variable after the call" {
	const pair = "function pair(out a: int32, out b: int32): void { a = 1; b = 2; }\n";
	assert unassignedReads(pair + "function f(): int32 { let a: int32; let b: int32; pair(out a, out b); return a + b; }", "a") == 0;
	assert unassignedReads(pair + "function f(): int32 { let a: int32; let b: int32; pair(out a, out b); return a + b; }", "b") == 0;
	assert unassignedReads("function one(out a: int32, v: int32): void { a = v; }\nfunction f(): int32 { let a: int32; one(out a, a); return a; }", "a") == 1;
}

test "useBeforeAssign: an out parameter takes an unassigned variable with or without the keyword, a ref parameter does not" {
	const fns = "function setTo(out a: int32, v: int32): void { a = v; }\nfunction bump(ref a: int32): void { a = a + 1; }\nfunction fill<T>(out a: T, v: T): void { a = v; }\n";
	assert unassignedReads(fns + "function f(): int32 { let a: int32; setTo(a, 3); return a; }", "a") == 0;
	assert unassignedReads(fns + "function f(): int32 { let a: int32; fill<int32>(a, 3); fill<int32>(a, 4); return a; }", "a") == 0;
	assert unassignedReads(fns + "function f(): int32 { let a: int32; bump(a); return a; }", "a") == 1;
	assert unassignedReads(fns + "function f(): int32 { let a: int32; bump(out a); return a; }", "a") == 0;
}

test "useBeforeAssign: an out parameter the callee never writes is not refused yet" {
	assert unassignedReads("function leave(out a: int32, c: boolean): void { if (c) { a = 1; } }", "a") == 0;
}

test "useBeforeAssign: an out argument does not assign a variable whose type has no default value" {
	const fns = "class Box { v: int32 = 1; }\nstruct Holder { b: Box; }\nfunction leaveBox(out b: Box): void { }\nfunction leaveHolder(out h: Holder): void { }\n";
	assert unassignedReads(fns + "function f(): int32 { let b: Box; leaveBox(out b); return b.v; }", "b") == 1;
	assert unassignedReads(fns + "function f(): int32 { let b: Box; leaveBox(b); return b.v; }", "b") == 1;
	assert unassignedReads(fns + "function f(): int32 { let h: Holder; leaveHolder(out h); return h.b.v; }", "h") == 1;
}

test "useBeforeAssign: a field or element write does not assign the variable" {
	assert unassignedReads("struct P { x: int32; y: int32 }\nfunction f(): int32 { let p: P; p.x = 1; return p.x; }", "p") == 1;
	assert unassignedReads("function f(): int32 { let a: int32[3]; a[0] = 1; return a[0]; }", "a") == 1;
	assert unassignedReads("function f(): int32 { let a: int32[3] = []; a[0] = 1; return a[0]; }", "a") == 0;
}

test "useBeforeAssign: compound assignment, update and a self-read read the variable" {
	assert unassignedReads("function f(): int32 { let n: int32; n += 1; return n; }", "n") == 1;
	assert unassignedReads("function f(): int32 { let n: int32; n++; return n; }", "n") == 1;
	assert unassignedReads("function f(): int32 { let n: int32; n = n + 1; return n; }", "n") == 1;
}

test "useBeforeAssign: a destructuring assignment assigns every identifier target" {
	assert unassignedReads("function f(): int32 { let a: int32; let b: int32; [a, b] = [1, 2]; return a + b; }", "a") == 0;
	assert unassignedReads("function f(): int32 { let a: int32; let b: int32; [a, b] = [1, 2]; return a + b; }", "b") == 0;
}

test "useBeforeAssign: a closure reading a variable assigned later is not checked, as TypeScript skips a captured variable" {
	assert unassignedReads("function f(): int32 { let n: int32; const g = (): int32 => n; n = 4; return g(); }", "n") == 0;
}

test "useBeforeAssign: a generic function is refused per instantiation and accepted when it assigns" {
	assert unassignedReads("function g<T>(v: T): T { let r: T; return r; }\nfunction h(): void { g<int32>(1); g<string>(\"s\"); }", "r") >= 1;
	assert unassignedReads("function g<T>(v: T): T { let r: T; r = v; return r; }\nfunction h(): void { g<int32>(1); g<string>(\"s\"); }", "r") == 0;
}
