import { fmt } from "../roundtrip";

test "fmt: an arrow prints its parameter and return types from their tree" {
	assert fmt("const h = (): { a: number, b: string } => x;\n") == "const h = (): { a: number; b: string } => x;\n";
	assert fmt("const p = (o: { a: number, b: string }) => o;\n") == "const p = (o: { a: number; b: string }) => o;\n";
}

test "fmt: a function expression prints its return type from its tree" {
	assert fmt("const g = function (): { a: number, b: string } { return x; };\n") == "const g = function (): { a: number; b: string } {\n\treturn x;\n};\n";
}

test "fmt: an arrow breaks a sole object pattern together with its type" {
	assert fmt("const f = ({ alpha, beta, gamma }: { alpha: number, beta: string, gamma: boolean }) => alpha;\n") == "const f = ({\n\talpha,\n\tbeta,\n\tgamma,\n}: {\n\talpha: number;\n\tbeta: string;\n\tgamma: boolean;\n}) => alpha;\n";
	assert fmt("const a = async ({ alpha, beta, gamma }: { alpha: number, beta: string, gamma: boolean }): Promise<number> => alpha;\n") == "const a = async ({\n\talpha,\n\tbeta,\n\tgamma,\n}: {\n\talpha: number;\n\tbeta: string;\n\tgamma: boolean;\n}): Promise<number> => alpha;\n";
}

test "fmt: a function expression breaks its parameters before a long return type" {
	assert fmt("const g = function (x: number): \"aaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbb\" | \"cccccccccccccccccc\" | \"ddddd\" { return \"ddddd\"; };\n") == "const g = function (\n\tx: number,\n): \"aaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbb\" | \"cccccccccccccccccc\" | \"ddddd\" {\n\treturn \"ddddd\";\n};\n";
	assert fmt("const b = async function (x: number): \"aaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbb\" | \"cccccccccccccccccc\" | \"ddddd\" { return \"ddddd\"; };\n") == "const b = async function (\n\tx: number,\n): \"aaaaaaaaaaaaaaa\" | \"bbbbbbbbbbbbbbbbb\" | \"cccccccccccccccccc\" | \"ddddd\" {\n\treturn \"ddddd\";\n};\n";
}
