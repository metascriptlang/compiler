import { fmt } from "../roundtrip";
import { parseSource } from "../../../parser/statements/validation";
import "../../../parser/statements/core";
import { Node, ProgramData, VariableDeclData } from "../../../ast/node";
import { defaultFormatOptions } from "../../../compiler/fmt/options";
import { isPoorlyBreakableMemberOrCallChain } from "../../../compiler/fmt/printer/calls";

function poorlyBreakable(source: string): boolean {
	const parsed = parseSource(source);
	if (!parsed.ok) throw new Error("internal: " + parsed.error);
	const options = defaultFormatOptions();
	options.source = source;
	const decl = (parsed.value.data as ProgramData).programStmts[0];
	return isPoorlyBreakableMemberOrCallChain((decl.data as VariableDeclData).initializer!, options);
}

test "fmt: a chain breaks into one call per line when it does not fit" {
	assert fmt("const total = items.map(item => item.price * item.quantity).filter(x => x > 0).reduce((a, b) => a + b, 0);\n") == "const total = items\n\t.map((item) => item.price * item.quantity)\n\t.filter((x) => x > 0)\n\t.reduce((a, b) => a + b, 0);\n";
	assert fmt("this.items.filter(item => item.active).map(item => item.name).join(\", \");\n") == "this.items\n\t.filter((item) => item.active)\n\t.map((item) => item.name)\n\t.join(\", \");\n";
	assert fmt("const result = await someObject.someMethod(argumentNumberOne).anotherMethod(argumentNumberTwo).finalMethod();\n") == "const result = await someObject\n\t.someMethod(argumentNumberOne)\n\t.anotherMethod(argumentNumberTwo)\n\t.finalMethod();\n";
	assert fmt("fetchData(urlWithAVeryLongName, optionsWithAVeryLongName).then(response => response.json()).then(data => process(data));\n") == "fetchData(urlWithAVeryLongName, optionsWithAVeryLongName)\n\t.then((response) => response.json())\n\t.then((data) => process(data));\n";
	assert fmt("const el = document.getElementById(\"some-element-id\").querySelector(\".some-class-name\").parentElement;\n") == "const el = document\n\t.getElementById(\"some-element-id\")\n\t.querySelector(\".some-class-name\").parentElement;\n";
	assert fmt("x.y.z.method(argumentNumberOne, argumentNumberTwo).another(argumentNumberThree, argumentNumberFour);\n") == "x.y.z\n\t.method(argumentNumberOne, argumentNumberTwo)\n\t.another(argumentNumberThree, argumentNumberFour);\n";
	assert fmt("const t = items.map(x => x * 2).filter(Boolean).slice(0, 10).length;\n") == "const t = items\n\t.map((x) => x * 2)\n\t.filter(Boolean)\n\t.slice(0, 10).length;\n";
}

test "fmt: a short chain, or one that ends in a hugged callback, stays on one line" {
	assert fmt("this.server.listen(port).then(() => { done(); });\n") == "this.server.listen(port).then(() => {\n\tdone();\n});\n";
	assert fmt("object.foo.bar.baz.qux();\n") == "object.foo.bar.baz.qux();\n";
	assert fmt("foo.bar().baz().qux();\n") == "foo.bar().baz().qux();\n";
	assert fmt("foo.bar(1).baz(2).qux(3);\n") == "foo.bar(1).baz(2).qux(3);\n";
	assert fmt("const x = await fetch(url).then(res => res.json());\n") == "const x = await fetch(url).then((res) => res.json());\n";
	assert fmt("x = a.b?.c?.d().e?.f();\n") == "x = a.b?.c?.d().e?.f();\n";
	assert fmt("const result = await client\n\t.query(sql)\n\t.where(\"a\", 1);\n") == "const result = await client.query(sql).where(\"a\", 1);\n";
	assert fmt("value.method().other(/* inline */ 1).third();\n") == "value.method().other(/* inline */ 1).third();\n";
}

test "fmt: a short head or a computed access joins its first call" {
	assert fmt("$.ajax(url).done(callback).fail(errorCallback);\n") == "$.ajax(url).done(callback).fail(errorCallback);\n";
	assert fmt("items[0].foo().bar();\n") == "items[0].foo().bar();\n";
	assert fmt("cy.get(\".btn\").click().should(\"have.class\", \"active\");\n") == "cy.get(\".btn\").click().should(\"have.class\", \"active\");\n";
	assert fmt("cy.get(\".btn\").click().should(\"have.class\", \"active\").and(\"be.visible\").then(() => { done(); });\n") == "cy.get(\".btn\")\n\t.click()\n\t.should(\"have.class\", \"active\")\n\t.and(\"be.visible\")\n\t.then(() => {\n\t\tdone();\n\t});\n";
}

test "fmt: a function argument before the last call breaks the chain" {
	assert fmt("somePromise.then(result => console.log(result)).catch(error => { handle(error); });\n") == "somePromise\n\t.then((result) => console.log(result))\n\t.catch((error) => {\n\t\thandle(error);\n\t});\n";
	assert fmt("Object.keys(someObject).filter(key => key.startsWith(\"prefix\")).forEach(key => { delete someObject[key]; });\n") == "Object.keys(someObject)\n\t.filter((key) => key.startsWith(\"prefix\"))\n\t.forEach((key) => {\n\t\tdelete someObject[key];\n\t});\n";
}

test "fmt: a comment or a blank line inside a chain keeps it broken" {
	assert fmt("a\n\t// leading\n\t.b()\n\t.c();\n") == "a\n\t// leading\n\t.b()\n\t.c();\n";
	assert fmt("promise\n\t.then(a) // after then\n\t.catch(b);\n") == "promise\n\t.then(a) // after then\n\t.catch(b);\n";
	assert fmt("promise\n\t.then(a)\n\n\t.catch(b)\n\t.finally(c);\n") == "promise\n\t.then(a)\n\n\t.catch(b)\n\t.finally(c);\n";
}

test "fmt: a chain of simple members and short calls is poorly breakable, one with a long argument or a second call is not" {
	assert poorlyBreakable("const v = a.b.c.d;");
	assert poorlyBreakable("const v = this.items.first();");
	assert poorlyBreakable("const v = a.b(\"x\");");
	assert !poorlyBreakable("const v = a.b(c, d);");
	assert !poorlyBreakable("const v = a.b(\"a string that is longer than a quarter of the line\");");
	assert !poorlyBreakable("const v = a.b().c().d();");
	assert !poorlyBreakable("const v = (a + b).c();");
	assert !poorlyBreakable("const v = a;");
}
