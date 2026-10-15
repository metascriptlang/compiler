import { compileToC } from "../helpers";
import { setParserDefines, resetParserDefines } from "../../parser/context";
import { createDefineTable, applyDefineSwitch } from "../../compiler/defines";

function compileAsCBuild(source: string): Result<string, string> {
	const t = createDefineTable();
	applyDefineSwitch(t, "-d:c");
	applyDefineSwitch(t, "-d:backend=c");
	setParserDefines(t);
	const r = compileToC(source);
	resetParserDefines();
	return r;
}

test "C: an extern function with a JS pattern is refused at the declaration" {
	const c = compileAsCBuild("extern function answer(): int32 from \"(40 + 2)\";\nconst v = answer();");
	assert !c.ok;
	assert c.error.contains("extern function 'answer': \"(40 + 2)\" is a JS pattern and needs the JS target");
	assert c.error.contains("when (js)");
}

test "C: a JS pattern with a placeholder is refused even when never called" {
	const c = compileAsCBuild("extern function twice(n: int32): int32 from \"(# * 2)\";\nconst v = 1;");
	assert !c.ok;
	assert c.error.contains("extern function 'twice'");
}

test "C: a JS pattern under when (js) builds, the C branch supplies the function" {
	const c = compileAsCBuild("when (js) {\n\textern function answer(): int32 from \"(40 + 2)\";\n} else {\n"
		+ "\tfunction answer(): int32 { return 42; }\n}\nconst v = answer();");
	assert c.ok;
}

test "C: a C symbol name in from stays a name" {
	const c = compileAsCBuild("extern function myAbs(n: int32): int32 from \"abs\";\nconst v = myAbs(-1);");
	assert c.ok;
	assert c.value.contains("abs(");
}

test "C: '$1' in from names the C function by the declared name" {
	const c = compileAsCBuild("extern function abs(n: int32): int32 from \"$1\";\nconst v = abs(-1);");
	assert c.ok;
	assert c.value.contains("abs(");
	assert !c.value.contains("$1");
}

test "C: 'prefix$1' in from names the prefixed C function" {
	const c = compileAsCBuild("extern function upper(c: int32): int32 from \"to$1\";\nconst v = upper(97);");
	assert c.ok;
	assert c.value.contains("toupper(");
}

test "C: an unknown '$' sequence in a from name is refused at the declaration" {
	const c = compileAsCBuild("extern function abs(n: int32): int32 from \"$12\";\nconst v = abs(-1);");
	assert !c.ok;
	assert c.error.contains("extern function 'abs': invalid from name \"$12\"");
}
