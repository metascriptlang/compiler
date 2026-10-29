import { fmt } from "../roundtrip";
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
