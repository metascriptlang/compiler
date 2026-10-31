import { refusedOnEveryBackend, compileToC, compileToJSWithStd } from "../helpers";

function refusal(call: string, form: string): string {
	const source = `let s = "  abc ";\n${call};\nconsole.log(s);`;
	return refusedOnEveryBackend(source, `strings are immutable, so string has no '${call.slice(2, call.indexOf("("))}': write ${form}`);
}

test "stringMutatorsRemoved: setLength is refused and names slice" {
	const verdict = refusal("s.setLength(3)", "`s = s.slice(0, n)`");
	assert verdict == "", verdict;
}

test "stringMutatorsRemoved: append is refused and names the concatenation" {
	const verdict = refusal("s.append(\"x\")", "`s = s + x`");
	assert verdict == "", verdict;
}

test "stringMutatorsRemoved: setSlice is refused and names slice" {
	const verdict = refusal("s.setSlice(0, 2)", "`s = s.slice(a, b)`");
	assert verdict == "", verdict;
}

test "stringMutatorsRemoved: stripInPlace is refused and names trim" {
	const verdict = refusal("s.stripInPlace()", "`s = s.trim()`");
	assert verdict == "", verdict;
}

test "stringMutatorsRemoved: capacity is refused and names length" {
	const verdict = refusedOnEveryBackend("const s = \"abc\";\nconst n = s.capacity();\nconsole.log(n);", "strings are immutable, so string has no 'capacity': write `s.length`");
	assert verdict == "", verdict;
}

test "stringMutatorsRemoved: the TypeScript forms stay accepted" {
	const source = "let s = \"  abc \";\ns = s.slice(1, 4);\ns = s.trim();\ns = s + \"x\";\ns += \"y\";\nconsole.log(s);";
	const c = compileToC(source);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileToJSWithStd(source);
	assert js.ok, js.ok ? "" : js.error;
}
