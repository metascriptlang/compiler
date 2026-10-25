import { compileProjectToCWithStd, compileProjectToJSWithStd, checkProjectDiagnostics, MapEntry } from "../helpers";

const grandModule = `import { Node, NodeKind, ClassDecoratorContext, metadataSet } from "std/meta";
macro tag(value: Node, context: ClassDecoratorContext): void {
	metadataSet(context.metadata, "a", { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 7, isFloat: false });
}
@tag
export class Grand { x: int32 = 1; }
`;

const parentModule = `import { Grand } from "./a";
export class Parent extends Grand { y: int32 = 2; }
`;

function childModule(imports: string, extra: string, parentName: string): string {
	return `import { Node, NodeKind, ClassDecoratorContext, metadataGet } from "std/meta";
${imports}
${extra}
let seen: int32 = 0;
macro probe(value: Node, context: ClassDecoratorContext): void {
	let read: Node = { kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: "none" };
	const found = metadataGet(context.metadata, "a");
	if (found != null) read = found;
	context.addInitializer({ kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "seen" }, right: read } });
}
@probe
class Child extends ${parentName} { w: int32 = 4; }
console.log(new Child().x);
console.log(seen);
`;
}

function project(main: string): MapEntry[] {
	return [
		{ entryPath: "test/a.ms", entrySource: grandModule },
		{ entryPath: "test/b.ms", entrySource: parentModule },
		{ entryPath: "test/main.ms", entrySource: main },
	];
}

function problemOf(main: string): string {
	const entries = project(main);
	const found = checkProjectDiagnostics(entries, "test/main.ms");
	if (found.length > 0) return found.join(" | ");
	const c = compileProjectToCWithStd(entries, "test/main.ms");
	if (c.startsWith("ERROR:")) return c;
	const js = compileProjectToJSWithStd(entries, "test/main.ms");
	if (js.startsWith("ERROR:")) return js;
	return "";
}

test "decorator metadata chain: a grandparent the child module never names still reaches the child" {
	const problem = problemOf(childModule(`import { Parent } from "./b";`, "", "Parent"));
	assert problem == "", "no namesake" + ": " + problem;
}

test "decorator metadata chain: a child module's own class named like the grandparent is not the grandparent" {
	const problem = problemOf(childModule(`import { Parent } from "./b";`, "class Grand { z: int32 = 3; }", "Parent"));
	assert problem == "", "namesake" + ": " + problem;
}

test "decorator metadata chain: the parent imported under an alias, beside a class named like it" {
	const problem = problemOf(childModule(`import { Parent as P } from "./b";`, "class Parent { z: int32 = 3; }", "P"));
	assert problem == "", "alias" + ": " + problem;
}
