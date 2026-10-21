import { checkOnly } from "../helpers";

function refusal(source: string): string {
	return checkOnly(source).errors.join("\n");
}

test "as between types that share no value is refused, a distinct judged by its base" {
	const cases: string[][] = [
		["type Name = distinct string;\nconst n = \"abc\" as Name;\nconst r = n as number;", "cannot convert Name to number — a string is not a number; read a character code with s.charCodeAt(i), a byte with s.byteAt(i), or parse the text"],
		["type Id = distinct int32;\nconst d = (7 as int32) as Id;\nconst r = d as string;", "cannot convert Id to string — format it with String(x) or x.toString()"],
		["type Id<T> = distinct int32;\nconst d = (7 as int32) as Id<string>;\nconst r = d as string;", "cannot convert Id<string> to string — format it with String(x) or x.toString()"],
		["type Name<T> = distinct string;\nconst n = \"abc\" as Name<int32>;\nconst r = n as boolean;", "cannot convert Name<int32> to boolean — a string is not a boolean; compare it instead (s != \"\")"],
		["const a: int32[] = [1, 2];\nconst r = a as number;", "cannot convert int32[] to number — an array is not a number; read an element or its length"],
		["const a: int32[] = [1, 2];\nconst r = a as string;", "cannot convert int32[] to string — an array is not a string; read an element or its length"],
		["type Ints = distinct int32[];\nconst a = [1, 2] as Ints;\nconst r = a as int32;", "cannot convert Ints to int32 — an array is not a int32; read an element or its length"],
		["const s = \"abc\";\nconst r = (s as string) as int32[];", "cannot convert string to int32[] — only an array converts to an array; build one ([x])"],
		["const i = 7 as int32;\nconst r = i as boolean;", "cannot convert int32 to boolean — a number is not a boolean; compare it instead (x != 0)"],
		["const i = 7 as int32;\nconst r = i as string | null;", "cannot convert int32 to string | null — format it with String(x) or x.toString()"],
		["const b = true;\nconst r = b as string | null;", "cannot convert boolean to string | null — format it with String(x) or x.toString()"],
	];
	for (const c of cases) {
		const text = refusal(c[0]);
		assert text.contains(c[1]), c[0] + " must be refused: " + text;
	}
}

test "as between types that overlap still checks" {
	const sources: string[] = [
		"const i = 7 as int32;\nconst r = i as number;",
		"const i = 7 as int32;\nconst r = i as int32 | null;",
		"const i = 7 as int32;\nconst r = i as int32 | string;",
		"const s: string = \"a\";\nconst r = s as \"a\" | \"b\";",
		"const a: int32[] = [1];\nconst r = a as int32[];",
		"function f(x: int32 | null): int32 { return x as int32; }",
		"const r = null as int32 | null;",
		"enum Color { Red, Green }\nconst r = Color.Green as int32;",
		"type Id = distinct int32;\nconst d = (7 as int32) as Id;\nconst r = d as int32 | null;",
		"type Name = distinct string;\nconst n = \"abc\" as Name;\nconst r = n as string | int32;",
	];
	for (const source of sources) {
		const text = refusal(source);
		assert text == "", source + " must check: " + text;
	}
}
