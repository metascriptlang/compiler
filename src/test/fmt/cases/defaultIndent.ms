import { defaultFormatOptions } from "../../../compiler/fmt/options";
import { fmt } from "../roundtrip";

function call(pad: int32): string {
	return "const v = callIt(" + "x".repeat(pad) + ", y);";
}

function broken(pad: int32, indent: string): string {
	return "const v = callIt(\n" + indent + "\t" + "x".repeat(pad) + ",\n" + indent + "\ty,\n" + indent + ");";
}

test "fmt defaults: tab indentation, tab width 2, line width 80" {
	const o = defaultFormatOptions();
	assert o.useTabs;
	assert o.tabWidth == 2;
	assert o.printWidth == 80;
}

test "fmt defaults: a line of exactly 80 columns with one tab stays flat and 81 breaks" {
	const fits = "function f() {\n\t" + call(56) + "\n}\n";
	assert fmt(fits) == fits;
	assert fmt("function f() {\n\t" + call(57) + "\n}\n") == "function f() {\n\t" + broken(57, "\t") + "\n}\n";
}

test "fmt defaults: two nested tabs count four columns toward the width" {
	const fits = "class C {\n\tm() {\n\t\t" + call(54) + "\n\t}\n}\n";
	assert fmt(fits) == fits;
	assert fmt("class C {\n\tm() {\n\t\t" + call(55) + "\n\t}\n}\n") == "class C {\n\tm() {\n\t\t" + broken(55, "\t\t") + "\n\t}\n}\n";
}
