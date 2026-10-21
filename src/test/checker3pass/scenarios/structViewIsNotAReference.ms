import { checkOnly } from "../helpers";

function errorsOf(source: string): string {
	return checkOnly(source).errors.join("\n");
}

const decls = "struct Pt { x: number; y: number; }\nstruct Box<T> { v: T; }\ninterface HasX { x: number; }\ninterface HasV { v: int32; }\n"
	+ "type Spot = distinct Pt;\ntype Spot2 = distinct Spot;\ntype Boxed<T> = distinct Box<T>;\n"
	+ "function rx(h: HasX): number { return h.x; }\nfunction rv(h: HasV): number { return h.v; }\n"
	+ "const s = ({ x: 1, y: 2 } as Pt) as Spot;\nconst b: Box<int32> = { v: 1 };\nconst g = b as Boxed<int32>;\n"
	+ "function mk(): Box<int32> { return { v: 1 }; }\n";

test "a struct viewed as an interface reads its fields in place" {
	const reads: string[] = [
		"const r = (s as HasX).x;",
		"const r = ((s as Spot2) as HasX).x;",
		"const r = (b as HasV).v;",
		"const r = (g as HasV).v;",
		"const r = (mk() as HasV).v;",
	];
	for (const read of reads) {
		const text = errorsOf(decls + read);
		assert text == "", read + " must check: " + text;
	}
}

test "a struct viewed as an interface is not an interface reference" {
	const cases: string[][] = [
		["const r = rx(s as HasX);", "got Pt, expected HasX"],
		["const r = rx((s as Spot2) as HasX);", "got Pt, expected HasX"],
		["const r = rv(b as HasV);", "got Box<int32>, expected HasV"],
		["const r = rv(g as HasV);", "got Box<int32>, expected HasV"],
		["const r = rv(mk() as HasV);", "got Box<int32>, expected HasV"],
		["const a: HasX[] = [s as HasX];", "Type 'Pt' is not assignable to type 'HasX'"],
		["const a: HasV[] = [g as HasV];", "Type 'Box<int32>' is not assignable to type 'HasV'"],
	];
	for (const c of cases) {
		const text = errorsOf(decls + c[0]);
		assert text.contains(c[1]), c[0] + " must be refused: " + text;
	}
}
