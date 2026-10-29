import { fmt } from "../roundtrip";

test "fmt: a chain of assignments breaks every operator together" {
	assert fmt("aaaaaaaaaaaaaaaaaaaaaaaa = bbbbbbbbbbbbbbbbbbbbbbbbb = cccccccccccccccccccccccc = ddddddddddddddddddddddd = 1;\n") == "aaaaaaaaaaaaaaaaaaaaaaaa =\n\tbbbbbbbbbbbbbbbbbbbbbbbbb =\n\tcccccccccccccccccccccccc =\n\tddddddddddddddddddddddd =\n\t\t1;\n";
	assert fmt("aaaaaaaaaaaaaaaaaaaaaaaa = bbbbbbbbbbbbbbbbbbbbbbbbb = cccccccccccccccccccccccc = someFunctionCall(ddddddddd, eeeeeeeeee);\n") == "aaaaaaaaaaaaaaaaaaaaaaaa =\n\tbbbbbbbbbbbbbbbbbbbbbbbbb =\n\tcccccccccccccccccccccccc =\n\t\tsomeFunctionCall(ddddddddd, eeeeeeeeee);\n";
	assert fmt("function f() { aaaaaaaaaaaaaaaaaaaaaaaa = bbbbbbbbbbbbbbbbbbbbbbbbb = cccccccccccccccccccccccc = ddddddddddddddddddd + eeeeeeeeeeeeeeeeee; }\n") == "function f() {\n\taaaaaaaaaaaaaaaaaaaaaaaa =\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbb =\n\t\tcccccccccccccccccccccccc =\n\t\t\tddddddddddddddddddd + eeeeeeeeeeeeeeeeee;\n}\n";
}

test "fmt: a chain of member assignments breaks every operator together" {
	assert fmt("window.someObject.property = window.otherObject.property = window.thirdObject.property = someValueExpression1;\n") == "window.someObject.property =\n\twindow.otherObject.property =\n\twindow.thirdObject.property =\n\t\tsomeValueExpression1;\n";
	assert fmt("a = b = c = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\n") == "a =\n\tb =\n\tc =\n\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\n";
}
