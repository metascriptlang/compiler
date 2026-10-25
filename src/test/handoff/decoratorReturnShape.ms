import { compileProjectToCWithStd, compileProjectToJSWithStd, checkProjectDiagnostics, MapEntry } from "../helpers";

function fieldMacro(returnType: string): MapEntry[] {
	const source = `import { Node, NodeKind, ClassFieldDecoratorContext } from "std/meta";
type Xform = (init: Node) => Node;
type Pair = Node[];
macro plus(value: Node, context: ClassFieldDecoratorContext): ${returnType} {
	return (init: Node): Node => ({ kind: NodeKind.NumberLiteral, line: init.line, column: init.column, value: 15, isFloat: false });
}
class K { @plus f: int32 = 1; }
console.log(new K().f);
`;
	return [{ entryPath: "test/main.ms", entrySource: source }];
}

test "decorator return shape: a field transformer is one whether the return type is written inline or through an alias" {
	for (const returnType of ["(init: Node) => Node", "Xform"]) {
		const entries = fieldMacro(returnType);
		const found = checkProjectDiagnostics(entries, "test/main.ms");
		assert found.length == 0, returnType + ": " + found.join(" | ");
		const c = compileProjectToCWithStd(entries, "test/main.ms");
		assert !c.startsWith("ERROR:"), returnType + ": " + c;
		const js = compileProjectToJSWithStd(entries, "test/main.ms");
		assert !js.startsWith("ERROR:"), returnType + ": " + js;
	}
}

test "decorator return shape: a return type that is not a function is still refused on a field" {
	for (const returnType of ["Node", "Pair"]) {
		const found = checkProjectDiagnostics(fieldMacro(returnType), "test/main.ms");
		let refused = false;
		for (const m of found) {
			if (m.contains("must return a field or nothing, got node")) refused = true;
		}
		assert refused, returnType + ": " + found.join(" | ");
	}
}
