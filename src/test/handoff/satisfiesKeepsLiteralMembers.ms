// `{…} satisfies T` keeps each literal member its context asked for, in T's fields and order:
// it reads and passes as the narrow type, reaches Readonly<T>, and never aliases into a writable T.
import { hasError, strictErrorCount } from "./helpers";

const SHAPE = "type Kind = \"circle\" | \"square\";\ninterface Shape { kind: Kind; size: number }\n";

test "satisfiesKeepsLiteralMembers: the member keeps its literal and the value passes as the narrow type" {
	const source = SHAPE +
		"type Circle = { kind: \"circle\"; size: number };\n" +
		"function takeCircle(c: Circle): number { return c.size; }\n" +
		"function area(s: Readonly<Shape>): number { return s.size; }\n" +
		"const p = { kind: \"circle\", size: 2 } satisfies Shape;\n" +
		"const k: \"circle\" = p.kind;\n" +
		"console.log(k, takeCircle(p), area(p));";
	assert strictErrorCount(source) == 0;
}

test "satisfiesKeepsLiteralMembers: a let binding and a nested literal keep theirs too" {
	const source = SHAPE +
		"interface Outer { inner: { kind: Kind }; n: number }\n" +
		"let r = { kind: \"circle\", size: 2 } satisfies Shape;\n" +
		"const o = { inner: { kind: \"circle\" }, n: 1 } satisfies Outer;\n" +
		"const a: \"circle\" = r.kind;\n" +
		"const b: \"circle\" = o.inner.kind;\n" +
		"console.log(a, b);";
	assert strictErrorCount(source) == 0;
}

test "satisfiesKeepsLiteralMembers: a write of the wider member is refused" {
	const source = SHAPE +
		"const p = { kind: \"circle\", size: 2 } satisfies Shape;\n" +
		"p.kind = \"square\";";
	assert hasError(source, "is not assignable to type '\"circle\"'");
}

test "satisfiesKeepsLiteralMembers: the value into a writable T is refused with the Readonly hint" {
	const source = SHAPE +
		"function mutate(s: Shape): void { s.kind = \"square\"; }\n" +
		"const p = { kind: \"circle\", size: 2 } satisfies Shape;\n" +
		"mutate(p);";
	assert hasError(source, "declare the parameter Readonly<Shape>");
}

test "satisfiesKeepsLiteralMembers: a member whose context is not a literal keeps the context's type" {
	const source = "const q = { kind: \"circle\", size: 2 } satisfies { kind: string; size: number };\n" +
		"function mutate(s: { kind: string; size: number }): void { s.kind = \"x\"; }\n" +
		"mutate(q);";
	assert strictErrorCount(source) == 0;
}

test "satisfiesKeepsLiteralMembers: true under boolean and a member under its enum keep their literal, a string under string does not" {
	const source = "enum K { A, B }\n" +
		"interface Tagged { k: K; ok: boolean; name: string }\n" +
		"const t = { k: K.A, ok: true, name: \"lib\" } satisfies Tagged;\n" +
		"const a: K.A = t.k;\n" +
		"const yes: true = t.ok;\n" +
		"console.log(a, yes);";
	assert strictErrorCount(source) == 0;
	const widened = "interface Named { name: string }\n" +
		"const t = { name: \"lib\" } satisfies Named;\n" +
		"const s: \"lib\" = t.name;";
	assert hasError(widened, "is not assignable to type '\"lib\"'");
}

test "satisfiesKeepsLiteralMembers: a nested literal reaches Readonly<T>, whose nested object is read-only too" {
	const source = SHAPE +
		"interface Outer { inner: { kind: Kind }; n: number }\n" +
		"function readOuter(o: Readonly<Outer>): string { return o.inner.kind; }\n" +
		"const o = { inner: { kind: \"circle\" }, n: 1 } satisfies Outer;\n" +
		"console.log(readOuter(o));";
	assert strictErrorCount(source) == 0;
}

test "satisfiesKeepsLiteralMembers: `as const` takes its context, keeps every literal and stays read-only" {
	const source = SHAPE +
		"function area(s: Readonly<Shape>): number { return s.size; }\n" +
		"const p = { kind: \"circle\", size: 2.5 } as const satisfies Shape;\n" +
		"const k: \"circle\" = p.kind;\n" +
		"const z: 2.5 = p.size;\n" +
		"const r: Readonly<Shape> = { kind: \"square\", size: 1 } as const;\n" +
		"console.log(k, z, area(p), area(r));";
	assert strictErrorCount(source) == 0;
	assert hasError(SHAPE + "const p = { kind: \"circle\", size: 2 } as const satisfies Shape;\np.size = 3;", "cannot write through Readonly<");
	assert hasError(SHAPE + "interface Outer { inner: { kind: Kind }; n: number }\nconst o = { inner: { kind: \"circle\" }, n: 1 } as const satisfies Outer;\no.inner.kind = \"square\";", "cannot write through Readonly<");
	assert hasError(SHAPE + "function mutate(s: Shape): void { s.kind = \"square\"; }\nconst p = { kind: \"circle\", size: 2 } as const satisfies Shape;\nmutate(p);", "declare the parameter Readonly<Shape>");
}
