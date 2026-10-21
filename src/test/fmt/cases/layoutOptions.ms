// Layout goldens for each option build.ms can set (fmt.printWidth, tabWidth, useTabs, singleQuote).
import { parseSource } from "../../../parser/statements/validation";
import "../../../parser/statements/core";
import { formatNode } from "../../../compiler/fmt/printer/index";
import { FormatOptions, defaultFormatOptions } from "../../../compiler/fmt/options";
import { checkLossless } from "../../../compiler/fmt/lossless";
import { astShape } from "../roundtrip";

const SOURCE = "import * as m from \"./m\";\nconst s = \"x\";\nfunction f(a: int32): int32 {\nif (a > 0) {\nreturn m.call(alpha, beta, gamma);\n}\nreturn 0;\n}\n";
const HEAD = "import * as m from \"./m\";\nconst s = \"x\";\nfunction f(a: int32): int32 {\n";

function format(source: string, options: FormatOptions): string {
	const parsed = parseSource(source);
	if (!parsed.ok) throw new Error("parse: " + parsed.error);
	options.source = source;
	const out = formatNode(parsed.value, options);
	if (!out.ok) throw new Error("fmt: " + out.error);
	return out.value;
}

function layoutHolds(options: FormatOptions, expected: string): boolean {
	const once = format(SOURCE, options);
	if (once != expected) throw new Error("layout:\n" + once);
	const kept = checkLossless(SOURCE, once);
	if (!kept.ok) throw new Error("lossy: " + kept.error);
	const before = parseSource(SOURCE);
	const after = parseSource(once);
	if (!before.ok || !after.ok || astShape(before.value) != astShape(after.value)) throw new Error("AST shape changed");
	return format(once, options) == once;
}

function options(printWidth: int32, tabWidth: int32, useTabs: boolean, singleQuote: boolean): FormatOptions {
	const o = defaultFormatOptions();
	o.printWidth = printWidth;
	o.tabWidth = tabWidth;
	o.useTabs = useTabs;
	o.singleQuote = singleQuote;
	return o;
}

test "fmt options: the defaults indent two spaces and keep a short block inline" {
	assert layoutHolds(defaultFormatOptions(), HEAD + "  if (a > 0) { return m.call(alpha, beta, gamma); }\n  return 0;\n}\n");
}

test "fmt options: useTabs indents with one tab per level" {
	assert layoutHolds(options(80, 2, true, false), HEAD + "\tif (a > 0) { return m.call(alpha, beta, gamma); }\n\treturn 0;\n}\n");
}

test "fmt options: tabWidth sets the space indent" {
	assert layoutHolds(options(80, 4, false, false), HEAD + "    if (a > 0) { return m.call(alpha, beta, gamma); }\n    return 0;\n}\n");
}

test "fmt options: printWidth breaks a block and a call that overflow it" {
	assert layoutHolds(options(30, 2, false, false), HEAD + "  if (a > 0) {\n    return m.call(\n      alpha,\n      beta,\n      gamma,\n    );\n  }\n  return 0;\n}\n");
}

test "fmt options: a tab counts tabWidth columns toward printWidth" {
	assert layoutHolds(options(40, 2, true, false), HEAD + "\tif (a > 0) {\n\t\treturn m.call(alpha, beta, gamma);\n\t}\n\treturn 0;\n}\n");
	assert layoutHolds(options(40, 8, true, false), HEAD + "\tif (a > 0) {\n\t\treturn m.call(\n\t\t\talpha,\n\t\t\tbeta,\n\t\t\tgamma,\n\t\t);\n\t}\n\treturn 0;\n}\n");
}

test "fmt options: singleQuote quotes a printed module path and keeps literals as written" {
	assert layoutHolds(options(80, 2, false, true), "import * as m from './m';\nconst s = \"x\";\nfunction f(a: int32): int32 {\n  if (a > 0) { return m.call(alpha, beta, gamma); }\n  return 0;\n}\n");
}
