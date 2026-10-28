import { refusedOnEveryBackend, compileToC, compileToJSWithStd, raiserErrors } from "../helpers";

const REST_NOT_LAST = "A rest element must be last in a destructuring pattern.";
const XS = "const xs: int32[] = [1, 2, 3, 4];\n";

test "destructuringRestLast: a rest element before the last target of an assignment is refused" {
	const verdict = refusedOnEveryBackend(XS + "let a: int32 = 0;\nlet b: int32 = 0;\nlet r: int32[] = [];\n[a, ...r, b] = xs;\nconsole.log(a, r.length, b);", REST_NOT_LAST);
	assert verdict == "", verdict;
}

test "destructuringRestLast: a rest element before the last name of a declaration is refused" {
	const verdict = refusedOnEveryBackend(XS + "const [a, ...r, b] = xs;\nconsole.log(a, r.length, b);", REST_NOT_LAST);
	assert verdict == "", verdict;
}

test "destructuringRestLast: a rest element first in a nested assignment pattern is refused" {
	const verdict = refusedOnEveryBackend("const xs: int32[][] = [[1, 2], [3, 4]];\nlet a: int32 = 0;\nlet b: int32 = 0;\nlet r: int32[] = [];\n[[...r, a], [b]] = xs;\nconsole.log(a, r.length, b);", REST_NOT_LAST);
	assert verdict == "", verdict;
}

test "destructuringRestLast: a rest property before the last property of an object declaration is refused" {
	const verdict = refusedOnEveryBackend("interface P { a: int32; b: int32; }\nconst p: P = { a: 1, b: 2 };\nconst { ...o, a } = p;\nconsole.log(a, o.b);", REST_NOT_LAST);
	assert verdict == "", verdict;
}

test "destructuringRestLast: a rest element last stays accepted on every backend" {
	const source = XS + "let a: int32 = 0;\nlet r: int32[] = [];\n[a, ...r] = xs;\nconst [c, ...s] = xs;\nconsole.log(a, r.length, c, s.length);";
	const c = compileToC(source);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileToJSWithStd(source);
	assert js.ok, js.ok ? "" : js.error;
	const raiser = raiserErrors(source);
	assert raiser == "", raiser;
}
