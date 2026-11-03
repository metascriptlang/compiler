import { checkProjectDiagnostics } from "../helpers";

function errors(source: string, text: string): int32 {
	let n: int32 = 0;
	for (const m of checkProjectDiagnostics([{ entryPath: "src/main.ms", entrySource: source }], "src/main.ms")) {
		if (m.indexOf(text) >= 0) n += 1;
	}
	return n;
}

const decls = "struct S { x: int32; }\nstruct H { p: Ptr<S>; }\nlet g: S = { x: 1 };\n"
	+ "function identity(p: Ptr<S>): Ptr<S> { return p; }\n"
	+ "function second(a: Ptr<S>, b: Ptr<S>): Ptr<S> { return b; }\n"
	+ "function wrap(p: Ptr<S>): H { return { p: p }; }\n"
	+ "function down(p: Ptr<S>): int32 { return p.x; }\n";
const escapes = "'s' escapes its stack frame";

test "ptrEscapeCall: a local's address returned through a call is refused" {
	assert errors(decls + "function f(): Ptr<S> { let s: S = { x: 5 }; return identity(s as Ptr<S>); }", escapes) == 1;
	assert errors(decls + "function f(): Ptr<S> { let s: S = { x: 5 }; return identity(identity(s as Ptr<S>)); }", escapes) == 1;
	assert errors(decls + "function f(): Ptr<S> { let s: S = { x: 5 }; return second(g as Ptr<S>, s as Ptr<S>); }", escapes) == 1;
	assert errors(decls + "function f(): H { let s: S = { x: 5 }; return wrap(s as Ptr<S>); }", escapes) == 1;
	assert errors(decls + "function f(): Ptr<S> { let s: S = { x: 5 }; const q = identity(s as Ptr<S>); return q; }", escapes) == 1;
}

test "ptrEscapeCall: a call result holding a local's address cannot reach module or heap storage" {
	assert errors(decls + "let gp: Ptr<S> = g as Ptr<S>;\nfunction f(): void { let s: S = { x: 5 }; gp = identity(s as Ptr<S>); }", escapes) == 1;
	assert errors(decls + "class Box { p: Ptr<S> = g as Ptr<S>; }\nfunction f(b: Box): void { let s: S = { x: 5 }; b.p = identity(s as Ptr<S>); }", escapes) == 1;
}

test "ptrEscapeCall: an address passed down or a call result with no pointer stays legal" {
	assert errors(decls + "function f(): int32 { let s: S = { x: 5 }; return down(s as Ptr<S>); }", "escapes") == 0;
	assert errors(decls + "function f(): int32 { let s: S = { x: 5 }; return identity(s as Ptr<S>).x; }", "escapes") == 0;
	assert errors(decls + "function f(): Ptr<S> { let s: S = { x: 5 }; down(s as Ptr<S>); return identity(g as Ptr<S>); }", "escapes") == 0;
	assert errors(decls + "function f(): int32 { let s: S = { x: 5 }; const q = identity(s as Ptr<S>); return q.x; }", "escapes") == 0;
}
