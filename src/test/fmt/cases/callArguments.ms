import { fmt } from "../roundtrip";

test "fmt: a callback written last hugs the call parentheses" {
	assert fmt("cell.setter((p) => { a(); });\n") == "cell.setter((p) => {\n\ta();\n});\n";
	assert fmt("foo(function () { return 1; });\n") == "foo(function () {\n\treturn 1;\n});\n";
	assert fmt("foo(a, b, (x) => { a(); });\n") == "foo(a, b, (x) => {\n\ta();\n});\n";
	assert fmt("router.get(\"/path\", authenticate, async (req, res) => { res.send(\"ok\"); });\n") == "router.get(\"/path\", authenticate, async (req, res) => {\n\tres.send(\"ok\");\n});\n";
}

test "fmt: an arrow with an expression body stays on the call line when it fits" {
	assert fmt("const r = items.filter(x => x > 0);\n") == "const r = items.filter((x) => x > 0);\n";
	assert fmt("promise.then(result => someFunction(result.veryLongPropertyName, result.anotherVeryLongPropertyName, 1));\n") == "promise.then((result) =>\n\tsomeFunction(\n\t\tresult.veryLongPropertyName,\n\t\tresult.anotherVeryLongPropertyName,\n\t\t1,\n\t),\n);\n";
	assert fmt("const y = items.filter(item => item.isActive && item.isVisible && item.hasPermission && item.isEnabled);\n") == "const y = items.filter(\n\t(item) =>\n\t\titem.isActive && item.isVisible && item.hasPermission && item.isEnabled,\n);\n";
	assert fmt("call(a, b, (c) => d ? e : f);\n") == "call(a, b, (c) => (d ? e : f));\n";
	assert fmt("call((c) => c ? someVeryLongConsequentExpression.withMember : someVeryLongAlternateExpression.withMember2);\n") == "call((c) =>\n\tc\n\t\t? someVeryLongConsequentExpression.withMember\n\t\t: someVeryLongAlternateExpression.withMember2,\n);\n";
	assert fmt("expect(screen.getByText(\"a very long text that is quite long indeed\")).toBeInTheDocument();\n") == "expect(\n\tscreen.getByText(\"a very long text that is quite long indeed\"),\n).toBeInTheDocument();\n";
	assert fmt("array.reduce((accumulator, current) => accumulator + current.value, initialValueForAccumulator);\n") == "array.reduce(\n\t(accumulator, current) => accumulator + current.value,\n\tinitialValueForAccumulator,\n);\n";
}

test "fmt: a callback written first hugs the call parentheses" {
	assert fmt("foo((x) => { a(); }, b);\n") == "foo((x) => {\n\ta();\n}, b);\n";
	assert fmt("setTimeout(function () { tick(); }, 500);\n") == "setTimeout(function () {\n\ttick();\n}, 500);\n";
}

test "fmt: arguments that cannot hug go one per line" {
	assert fmt("foo(aVeryLongArgumentNumberOne, aVeryLongArgumentNumberTwo, aVeryLongArgumentNumberThree, four);\n") == "foo(\n\taVeryLongArgumentNumberOne,\n\taVeryLongArgumentNumberTwo,\n\taVeryLongArgumentNumberThree,\n\tfour,\n);\n";
	assert fmt("foo(aVeryLongArgumentNumberOne, aVeryLongArgumentNumberTwo, aVeryLongArgumentNumberThree, (x) => { a(); });\n") == "foo(\n\taVeryLongArgumentNumberOne,\n\taVeryLongArgumentNumberTwo,\n\taVeryLongArgumentNumberThree,\n\t(x) => {\n\t\ta();\n\t},\n);\n";
	assert fmt("foo(a => a + 1, b => b + 2);\n") == "foo(\n\t(a) => a + 1,\n\t(b) => b + 2,\n);\n";
	assert fmt("foo(bar, () => { a(); }, baz);\n") == "foo(\n\tbar,\n\t() => {\n\t\ta();\n\t},\n\tbaz,\n);\n";
	assert fmt("new Foo(aVeryLongArgumentNumberOne, aVeryLongArgumentNumberTwo, aVeryLongArgumentNumberThree, four);\n") == "new Foo(\n\taVeryLongArgumentNumberOne,\n\taVeryLongArgumentNumberTwo,\n\taVeryLongArgumentNumberThree,\n\tfour,\n);\n";
	assert fmt("promise.then(() => { a(); }, () => { b(); });\n") == "promise.then(\n\t() => {\n\t\ta();\n\t},\n\t() => {\n\t\tb();\n\t},\n);\n";
	assert fmt("const fn = useCallback(async (event) => { await handle(event); }, [handle]);\n") == "const fn = useCallback(\n\tasync (event) => {\n\t\tawait handle(event);\n\t},\n\t[handle],\n);\n";
}

test "fmt: a hook, a test call and require keep their arguments on one line" {
	assert fmt("useEffect(() => { a(); }, [dep1, dep2]);\n") == "useEffect(() => {\n\ta();\n}, [dep1, dep2]);\n";
	assert fmt("it(\"does something really long and descriptive that goes past the line width limit ok\", () => { a(); });\n") == "it(\"does something really long and descriptive that goes past the line width limit ok\", () => {\n\ta();\n});\n";
	assert fmt("test(\"does a thing\", async () => { await run(); });\n") == "test(\"does a thing\", async () => {\n\tawait run();\n});\n";
	assert fmt("const mod = require(\"some-module\");\n") == "const mod = require(\"some-module\");\n";
}

test "fmt: a call inside a hugged argument and a call of a call" {
	assert fmt("outer(inner(() => { a(); }));\n") == "outer(\n\tinner(() => {\n\t\ta();\n\t}),\n);\n";
	assert fmt("fn(a)(b)(c);\n") == "fn(a)(b)(c);\n";
}

test "fmt: a hugged signature that does not fit gives the hug up" {
	assert fmt("promise.then(function (veryLongParameterNumberOne, veryLongParameterNumberTwo, veryLongParameterNumberThree) { a(); });\n") == "promise.then(\n\tfunction (\n\t\tveryLongParameterNumberOne,\n\t\tveryLongParameterNumberTwo,\n\t\tveryLongParameterNumberThree,\n\t) {\n\t\ta();\n\t},\n);\n";
	assert fmt("promise.then((veryLongParameterNumberOne, veryLongParameterNumberTwo, veryLongParameterNumberThree, four) => { a(); });\n") == "promise.then(\n\t(\n\t\tveryLongParameterNumberOne,\n\t\tveryLongParameterNumberTwo,\n\t\tveryLongParameterNumberThree,\n\t\tfour,\n\t) => {\n\t\ta();\n\t},\n);\n";
}

test "fmt: comments, blank lines and spread in an argument list" {
	assert fmt("foo(a, b /* last */);\n") == "foo(a, b /* last */);\n";
	assert fmt("foo(\n\t// leading comment\n\ta,\n\tb,\n);\n") == "foo(\n\t// leading comment\n\ta,\n\tb,\n);\n";
	assert fmt("foo(\n\ta,\n\n\tb,\n);\n") == "foo(\n\ta,\n\n\tb,\n);\n";
	assert fmt("foo(...args);\n") == "foo(...args);\n";
}
