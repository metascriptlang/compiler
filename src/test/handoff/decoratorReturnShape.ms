import { compileProjectToCWithStd, compileProjectToJSWithStd, checkProjectDiagnostics, MapEntry } from "../helpers";

function aliasDecl(returnType: string): string {
	if (returnType == "Xform") return "type Xform = (init: Node) => Node;";
	if (returnType == "Pair") return "type Pair = Node[];";
	return "";
}

const TRANSFORMER = "(init: Node): Node => ({ kind: NodeKind.NumberLiteral, line: init.line, column: init.column, value: 15, isFloat: false })";
const NODE = "{ kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 15, isFloat: false }";

function fieldMacro(returnType: string, returned: string): MapEntry[] {
	const source = `import { Node, NodeKind, ClassFieldDecoratorContext } from "std/meta";
${aliasDecl(returnType)}
macro plus(value: Node, context: ClassFieldDecoratorContext): ${returnType} {
	return ${returned};
}
class K { @plus f: int32 = 1; }
console.log(new K().f);
`;
	return [{ entryPath: "test/main.ms", entrySource: source }];
}

test "decorator return shape: a field transformer is one whether the return type is written inline or through an alias" {
	for (const returnType of ["(init: Node) => Node", "Xform"]) {
		const entries = fieldMacro(returnType, TRANSFORMER);
		const found = checkProjectDiagnostics(entries, "test/main.ms");
		assert found.length == 0, returnType + ": " + found.join(" | ");
		const c = compileProjectToCWithStd(entries, "test/main.ms");
		assert !c.startsWith("ERROR:"), returnType + ": " + c;
		const js = compileProjectToJSWithStd(entries, "test/main.ms");
		assert !js.startsWith("ERROR:"), returnType + ": " + js;
	}
}

test "decorator return shape: a return type that is not a function is still refused on a field" {
	for (const shape of [["Node", NODE], ["Pair", `[${NODE}]`]]) {
		const returnType = shape[0];
		const found = checkProjectDiagnostics(fieldMacro(returnType, shape[1]), "test/main.ms");
		let refused = false;
		for (const m of found) {
			if (m.contains("must return a field or nothing, got ")) refused = true;
		}
		assert refused, returnType + ": " + found.join(" | ");
	}
}
