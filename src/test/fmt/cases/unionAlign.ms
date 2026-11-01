import { fmt, assertFmtLossless, assertFmtIdempotent } from "../roundtrip";
import { parseSource } from "../../../parser/statements/validation";
import "../../../parser/statements/core";
import { formatNode } from "../../../compiler/fmt/printer/index";
import { defaultFormatOptions } from "../../../compiler/fmt/options";

function fmtSpaces(source: string): string {
	const parsed = parseSource(source);
	if (!parsed.ok) throw new Error("parse: " + parsed.error);
	const options = defaultFormatOptions();
	options.useTabs = false;
	options.tabWidth = 2;
	options.source = source;
	const out = formatNode(parsed.value, options);
	if (!out.ok) throw new Error("fmt: " + out.error);
	return out.value;
}

test "fmt: an object variant of a broken union closes at the union indent plus the align under tabs" {
	assert fmt("type T = { aaaaaaaaaaaaaaaa: number; bbbbbbbbbbbbbbbbbbbb: string; cccccccccccccccccc: boolean } | { ddddddddddd: number; eeeeeeeeeeeeeeeeee: string } | null;\n") == "type T =\n\t| {\n\t\t\taaaaaaaaaaaaaaaa: number;\n\t\t\tbbbbbbbbbbbbbbbbbbbb: string;\n\t\t\tcccccccccccccccccc: boolean;\n\t  }\n\t| { ddddddddddd: number; eeeeeeeeeeeeeeeeee: string }\n\t| null;\n";
	assert fmt("let v: { aaaaaaaaaaaaaaaa: number; bbbbbbbbbbbbbbbbbbbb: string; cccccccccccccccccc: boolean } | { ddddddddddd: number; eeeeeeeeeeeeeeeeee: string } | null;\n") == "let v:\n\t| {\n\t\t\taaaaaaaaaaaaaaaa: number;\n\t\t\tbbbbbbbbbbbbbbbbbbbb: string;\n\t\t\tcccccccccccccccccc: boolean;\n\t  }\n\t| { ddddddddddd: number; eeeeeeeeeeeeeeeeee: string }\n\t| null;\n";
}

test "fmt: an object variant of a broken union keeps the align beside the indent under spaces" {
	assert fmtSpaces("type T = { aaaaaaaaaaaaaaaa: number; bbbbbbbbbbbbbbbbbbbb: string; cccccccccccccccccc: boolean } | { ddddddddddd: number; eeeeeeeeeeeeeeeeee: string } | null;\n") == "type T =\n  | {\n      aaaaaaaaaaaaaaaa: number;\n      bbbbbbbbbbbbbbbbbbbb: string;\n      cccccccccccccccccc: boolean;\n    }\n  | { ddddddddddd: number; eeeeeeeeeeeeeeeeee: string }\n  | null;\n";
	assert fmtSpaces("let v: { aaaaaaaaaaaaaaaa: number; bbbbbbbbbbbbbbbbbbbb: string; cccccccccccccccccc: boolean } | { ddddddddddd: number; eeeeeeeeeeeeeeeeee: string } | null;\n") == "let v:\n  | {\n      aaaaaaaaaaaaaaaa: number;\n      bbbbbbbbbbbbbbbbbbbb: string;\n      cccccccccccccccccc: boolean;\n    }\n  | { ddddddddddd: number; eeeeeeeeeeeeeeeeee: string }\n  | null;\n";
}

test "fmt: a broken union in a type literal member takes a leading bar and keeps it on a second pass" {
	const source = "type A = { getItemHeightxxxx?: ((item: T, index: number, columnWidth: number) => number) | null };\n";
	assert assertFmtLossless(source);
	assert assertFmtIdempotent(source);
	assert fmt(source) == "type A = {\n\tgetItemHeightxxxx?:\n\t\t| ((item: T, index: number, columnWidth: number) => number)\n\t\t| null;\n};\n";
}

test "fmt: a broken union in a parameter's inline object type takes a leading bar and keeps it on a second pass" {
	const source = "export function MasonryList<T>(props: {\n\tgetItemHeight?: ((item: T, index: number, columnWidth: number) => number) | null;\n}): NeonNode {\n}\n";
	assert assertFmtLossless(source);
	assert assertFmtIdempotent(source);
	assert fmt(source).contains("\tgetItemHeight?:\n\t\t| ((item: T, index: number, columnWidth: number) => number)\n\t\t| null;\n");
}
