import { compileToC } from "../helpers";

function copies(code: string): int32 {
	return (code.split("msStringCopy(").length - 1) as int32;
}

test "topLevelCursors: a top-level for-of over a call result binds its element without a copy" {
	const result = compileToC("let n = 0;\nfor (const w of \"a b c\".split(\" \")) { if (w == \"b\") { n++; } }\nconsole.log(n);");
	assert result.ok, result.error;
	assert copies(result.value) == 0;
}

test "topLevelCursors: a top-level for-of over a global still copies, as a global is never a cursor source" {
	const result = compileToC("const ps = \"a b c\".split(\" \");\nlet n = 0;\nfor (const w of ps) { ps[0] = \"z\"; if (w == \"b\") { n++; } }\nconsole.log(n);");
	assert result.ok, result.error;
	assert copies(result.value) >= 1;
}
