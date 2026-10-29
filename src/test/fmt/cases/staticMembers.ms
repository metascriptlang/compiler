import { fmt } from "../roundtrip";

test "fmt: a long static member path breaks before the first member that does not fit" {
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccccc.dddddddddddddddddddd.eeeeeeeeeeeeeee);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccccc\n\t\t.dddddddddddddddddddd.eeeeeeeeeeeeeee,\n);\n";
	assert fmt("foo(this.aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccccc.dddddddddddddddddddd.eeeeeeeeeeeeeee);\n") == "foo(\n\tthis.aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccccc\n\t\t.dddddddddddddddddddd.eeeeeeeeeeeeeee,\n);\n";
	assert fmt("aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccccc.dddddddddddddddddddd.eeeeeeeeeeeeeee.fffff;\n") == "aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccccc\n\t.dddddddddddddddddddd.eeeeeeeeeeeeeee.fffff;\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb[cccccccccccccccccccccc].dddddddddddddddddddd.eeeeeeeeeeeeeee.ffff);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb[cccccccccccccccccccccc]\n\t\t.dddddddddddddddddddd.eeeeeeeeeeeeeee.ffff,\n);\n";
	assert fmt("foo(someFunction(argumentNumberOne, argumentNumberTwo).resultProperty.anotherProperty.finalProperty.last);\n") == "foo(\n\tsomeFunction(argumentNumberOne, argumentNumberTwo).resultProperty\n\t\t.anotherProperty.finalProperty.last,\n);\n";
}

test "fmt: a short member path or one over a lone identifier is not broken" {
	assert fmt("foo(a.b.c.d);\n") == "foo(a.b.c.d);\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbb);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbb,\n);\n";
	assert fmt("foo(this.state.items.filter(item => item.active).length);\n") == "foo(this.state.items.filter((item) => item.active).length);\n";
}

test "fmt: a member path under an assignment breaks after an identifier target only, and never under new" {
	assert fmt("x.y = aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccccc.dddddddddddddddddddd.eeeeeeeeeeeeeee;\n") == "x.y =\n\taaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccccc.dddddddddddddddddddd.eeeeeeeeeeeeeee;\n";
	assert fmt("foo(new aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccccc.dddddddddddddddddddd.eeeeeeeeeee());\n") == "foo(\n\tnew aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccccc.dddddddddddddddddddd.eeeeeeeeeee(),\n);\n";
}
