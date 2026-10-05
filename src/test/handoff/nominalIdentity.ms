import { checkProjectDiagnostics, MapEntry } from "../helpers";
import { strictErrorCount } from "./helpers";

function errorsOf(main: string): string[] {
	const entries: MapEntry[] = [
		{ entryPath: "src/door.ms", entrySource: "export enum Mode { A, B }\nexport type Door = Mode;\n" },
		{ entryPath: "src/light.ms", entrySource: "export enum Mode { X, Y }\n" },
		{ entryPath: "src/main.ms", entrySource: main },
	];
	return checkProjectDiagnostics(entries, "src/main.ms");
}

test "nominal identity: two enums that share a name are two types" {
	const pre = "import { Mode as Door } from \"./door\";\nimport { Mode as Light } from \"./light\";\n";
	assert errorsOf(pre + "const same: boolean = Door.A == Light.X;\n").length > 0;
	assert errorsOf(pre + "function take(m: Light): int32 { return 1; }\nconst n = take(Door.A);\n").length > 0;
	assert errorsOf(pre + "const d: Door = Door.B;\nconst same: boolean = d == Door.A && Light.X == Light.Y;\n").length == 0;
	assert errorsOf("import { Mode, Door } from \"./door\";\nconst d: Door = Mode.B;\nconst same: boolean = Mode.A == d;\n").length == 0;
}

test "nominal identity: a declared type named like a builtin generic is that declaration" {
	const userTypes = [
		"class Vec<T> { items: T[] = []; tag(): string { return \"vec\"; } }\nconst v: Vec<int32> = new Vec<int32>();\nconst s: string = v.tag();",
		"class Arc<T> { value: T; constructor(value: T) { this.value = value; } }\nconst a: Arc<int32> = new Arc<int32>(7);\nconst n: int32 = a.value;",
		"class Locked<T> { inner: T; constructor(inner: T) { this.inner = inner; } }\nconst l: Locked<string> = new Locked<string>(\"x\");\nconst s: string = l.inner;",
		"interface Cursor<T> { at: T; }\nconst c: Cursor<int32> = { at: 1 };\nconst n: int32 = c.at;",
	];
	for (const src of userTypes) {
		assert strictErrorCount(src) == 0, src;
	}
	assert strictErrorCount("const v: Vec<int32> = [1, 2];\nconst n: int32 = v.length;") == 0;
	assert strictErrorCount("const r: Result<int32, string> = Result.ok(1);") == 0;
}

test "nominal identity: as between unions without a conversion is refused" {
	const refused = [
		"function f(x: string | int32): int32 | string | boolean { return x as int32 | string | boolean; }",
		"class Mark { line: int32 = 0; }\nclass Spot { line: int32 = 2; }\nclass Other { tag: string = \"o\"; }\nfunction f(x: Other | null): Mark | Spot | null { return x as Mark | Spot | null; }",
	];
	for (const src of refused) {
		assert strictErrorCount(src) > 0, src;
	}
	const converted = [
		"class Mark { line: int32 = 0; }\nclass Spot { line: int32 = 2; }\nfunction f(x: Spot | null): Mark | Spot | null { return x as Mark | Spot | null; }",
		"class Row { value: int32 = 1; }\nfunction f(x: number | Row | null): Row | null { return x as Row | null; }",
		"function f(x: int32 | string): int32 | string { return x as int32 | string; }",
	];
	for (const src of converted) {
		assert strictErrorCount(src) == 0, src;
	}
}
