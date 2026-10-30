// A brand over an array relates as a TypeScript intersection does: it widens to its base, the base never
// narrows to it without `as`, two brands over one base are different types, and an intersection the
// checker cannot represent is an error instead of the first operand.
import { checkProjectDiagnostics, MapEntry } from "../helpers";

const head = "type Bytes = uint8[] & { __brand: \"Bytes\" };\ntype Words = uint8[] & { __brand: \"Words\" };\n"
	+ "type Wide = int32[] & { __brand: \"Bytes\" };\n";

function diagnostics(body: string): string[] {
	const entries: MapEntry[] = [{ entryPath: "src/main.ms", entrySource: head + body }];
	return checkProjectDiagnostics(entries, "src/main.ms");
}

function errors(body: string): string[] {
	const out: string[] = [];
	for (const m of diagnostics(body)) {
		if (m.indexOf("is declared but never used") < 0) out.push(m);
	}
	return out;
}

function lines(d: string[]): string {
	return d.join(" | ");
}

test "brandArrayRelations: a brand over an array widens to its base and `as` makes one" {
	const d = errors("function f(raw: uint8[]): int32 {\n const b = raw as Bytes;\n const back: uint8[] = b;\n const s: Readonly<Span<uint8>> = b;\n const r: Readonly<uint8[]> = b;\n return back.length + s.length + r.length;\n}\nconsole.log(f([1]));");
	assert d.length == 0, lines(d);
}

test "brandArrayRelations: the base array does not narrow to its brand without `as`" {
	const d = errors("function f(raw: uint8[]): Bytes {\n const wrong: Bytes = raw;\n return wrong;\n}\nconsole.log(f([1]).length);");
	assert d.length == 1 && d[0].indexOf("Type 'uint8[]' is not assignable to type 'Bytes'") >= 0, lines(d);
}

test "brandArrayRelations: two brands over one array base do not cross, nor do two element types" {
	const a = errors("function f(b: Bytes): Words {\n const wrong: Words = b;\n return wrong;\n}\nconsole.log(f([1] as Bytes).length);");
	assert a.length == 1 && a[0].indexOf("Type 'Bytes' is not assignable to type 'Words'") >= 0, lines(a);
	const e = errors("function f(b: Bytes): Wide {\n const wrong: Wide = b;\n return wrong;\n}\nconsole.log(f([1] as Bytes).length);");
	assert e.length == 1 && e[0].indexOf("Type 'Bytes' is not assignable to type 'Wide'") >= 0, lines(e);
}

test "brandArrayRelations: an intersection the checker cannot represent is an error, not its first operand" {
	for (const t of ["string & { name: string }", "uint8[] & int32"]) {
		const d = errors("type T = " + t + ";\nfunction f(x: T): void {}\nconsole.log(1);");
		assert d.length == 1 && d[0].indexOf("cannot represent the intersection") >= 0, t + ": " + lines(d);
	}
}
