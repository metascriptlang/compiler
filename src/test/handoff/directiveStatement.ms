import { compileToCWithStd } from "../helpers";
import { hasError } from "./helpers";

const INVALID = "invalid directive '@nosuch'";

test "a directive statement whose name is no macro and no compiler directive is an error" {
	assert hasError("@nosuch(1);\nconsole.log(\"after\");", INVALID);
	assert hasError("function f(): void {\n\t@nosuch;\n\tconsole.log(\"in\");\n}\nf();", INVALID);
}

test "a compiler directive and a macro invoked as a directive statement stay valid" {
	const src = `
import { Node } from "std/meta";
macro keep(value: Node): Node { return value; }
function main(): void {
	@emit("/* directive kept */");
	@keep(console.log("kept"));
}
main();
`;
	const c = compileToCWithStd(src);
	assert c.ok;
	if (c.ok) assert c.value.contains("/* directive kept */");
}
