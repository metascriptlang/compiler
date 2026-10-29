import { fmt } from "../roundtrip";

test "fmt: a signature whose return type does not fit breaks its parameters first" {
	assert fmt("function k(x: number): \"aaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbb\" | \"cccccccccccccccccc\" | \"ddddddd\" { return \"ddddd\"; }\n") == "function k(\n\tx: number,\n): \"aaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbb\" | \"cccccccccccccccccc\" | \"ddddddd\" {\n\treturn \"ddddd\";\n}\n";
	assert fmt("function q(x: number, y: string): \"aaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbb\" | \"cccccccccccccccccc\" | \"ddddddd\" { return \"ddddd\"; }\n") == "function q(\n\tx: number,\n\ty: string,\n): \"aaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbb\" | \"cccccccccccccccccc\" | \"ddddddd\" {\n\treturn \"ddddd\";\n}\n";
	assert fmt("class C { k(x: number): \"aaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbb\" | \"cccccccccccccccccc\" | \"ddddddd\" { return \"ddddd\"; } }\n") == "class C {\n\tk(\n\t\tx: number,\n\t):\n\t\t| \"aaaaaaaaaaaaaaa\"\n\t\t| \"bbbbbbbbbbbbbbbbb\"\n\t\t| \"cccccccccccccccccc\"\n\t\t| \"ddddddd\" {\n\t\treturn \"ddddd\";\n\t}\n}\n";
	assert fmt("function s(x: number): \"aaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbb\" { return \"a\"; }\n") == "function s(x: number): \"aaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbb\" {\n\treturn \"a\";\n}\n";
}

test "fmt: a sole object pattern parameter and its object type break together" {
	assert fmt("function g({ alpha, beta, gamma }: { alpha: number; beta: string; gamma: boolean }) { return alpha; }\n") == "function g({\n\talpha,\n\tbeta,\n\tgamma,\n}: {\n\talpha: number;\n\tbeta: string;\n\tgamma: boolean;\n}) {\n\treturn alpha;\n}\n";
	assert fmt("class C { m({ alpha, beta, gamma }: { alpha: number; beta: string; gamma: boolean }) { return alpha; } }\n") == "class C {\n\tm({ alpha, beta, gamma }: { alpha: number; beta: string; gamma: boolean }) {\n\t\treturn alpha;\n\t}\n}\n";
	assert fmt("function p({ alpha, ...rest }: { alpha: number; beta: string; gamma: boolean; deltaaaaaaaaaaaaaaaaaaaa: string }) { return alpha; }\n") == "function p({\n\talpha,\n\t...rest\n}: {\n\talpha: number;\n\tbeta: string;\n\tgamma: boolean;\n\tdeltaaaaaaaaaaaaaaaaaaaa: string;\n}) {\n\treturn alpha;\n}\n";
	assert fmt("function g({ a }: { a: number }) { return a; }\n") == "function g({ a }: { a: number }) {\n\treturn a;\n}\n";
}
