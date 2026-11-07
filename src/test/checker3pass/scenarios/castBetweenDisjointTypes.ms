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

test "as from an array, a number, a string or a function to a class instance is refused" {
	const box = "class Box { n: number = 1; }\n";
	const cases: string[][] = [
		[box + "const a: int32[] = [1, 2];\nconst r = a as Box;", "cannot convert int32[] to Box — an array is not a Box; read an element or its length"],
		[box + "const x: number = 5;\nconst r = x as Box;", "cannot convert number to Box —"],
		[box + "const s: string = \"hi\";\nconst r = s as Box;", "cannot convert string to Box —"],
		[box + "const f = (): int32 => 1;\nconst r = f as Box;", "cannot convert"],
		[box + "const a: uint8[] = [1];\nconst r = a as Box | null;", "cannot convert uint8[] to Box | null — an array is not a Box"],
	];
	for (const c of cases) {
		const text = refusal(c[0]);
		assert text.contains(c[1]), c[0] + " must be refused: " + text;
	}
}

test "as between class instances, null and a class still checks" {
	const classes = "class Base { n: number = 1; }\nclass Sub extends Base { m: number = 2; }\n";
	const sources: string[] = [
		classes + "const r = new Sub() as Base;",
		classes + "const b: Base = new Sub();\nconst r = b as Sub;",
		classes + "const r = null as Base | null;",
		classes + "function f(x: Base | null): Base { return x as Base; }",
	];
	for (const source of sources) {
		const text = refusal(source);
		assert text == "", source + " must check: " + text;
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

test "as between an address and a float, a boolean or a narrower integer is refused" {
	const p = "const p = null as Ptr<void>;\n";
	const cases: string[][] = [
		["const f = 1.5;\nconst r = f as Ptr<void>;", "cannot convert float64 to Ptr<void> — only an integer holds an address"],
		["const b = true;\nconst r = b as Ptr<void>;", "cannot convert boolean to Ptr<void> — only an integer holds an address"],
		[p + "const r = p as int32;", "cannot convert Ptr<void> to int32 — an address does not fit in int32; read it with `as int64` or `as uint64`"],
		[p + "const r = p as uint32;", "an address does not fit in uint32"],
		[p + "const r = p as float64;", "cannot convert Ptr<void> to float64 — a pointer is not a number"],
		[p + "function g<T>(q: Ptr<void>): T { return q as T; }\nconst r = g<int32>(p);", "an address does not fit in int32"],
		["function h<T>(x: T): Ptr<void> { return x as Ptr<void>; }\nconst r = h(1.5);", "only an integer holds an address"],
	];
	for (const c of cases) {
		const text = refusal(c[0]);
		assert text.contains(c[1]), c[0] + " must be refused: " + text;
	}
}

test "as between an address and a 64-bit integer, or an integer into an address, still checks" {
	const sources: string[] = [
		"const p = null as Ptr<void>;\nconst a = p as int64;\nconst b = p as uint64;",
		"const n = 16 as int64;\nconst p = n as Ptr<void>;",
		"const n = 16 as int32;\nconst p = n as Ptr<void>;",
	];
	for (const src of sources) {
		const text = refusal(src);
		assert text == "", src + " must check: " + text;
	}
}
