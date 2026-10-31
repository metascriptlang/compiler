import { checkOnlyEdited } from "../helpers";
import { Node, NodeKind, NodeFlag, ProgramData, ClassDeclData, ConstructorDeclData } from "../../../ast/node";

function checkWith(source: string, signatures: int32, abstractAt: int32 = -1): string {
	return checkOnlyEdited(source, (program: Node): void => {
		for (const stmt of (program.data as ProgramData).programStmts) {
			if (stmt.kind != NodeKind.ClassDecl) continue;
			let seen: int32 = 0;
			for (const member of (stmt.data as ClassDeclData).classBody) {
				if (member.kind != NodeKind.ConstructorDecl) continue;
				if (seen < signatures) (member.data as ConstructorDeclData).ctorFlags = "overload";
				if (seen == abstractAt) member.flags = member.flags.incl(NodeFlag.Abstract);
				seen += 1;
			}
		}
	}).errors.join("\n");
}

const CLASS = `class C {
	v: string = "";
	constructor(a: string) {}
	constructor(a: number) {}
	constructor(a: string | number) { this.v = "x"; }
}
`;

test "constructor signatures rank for a new and the implementation is not a candidate" {
	assert checkWith(CLASS + `const a = new C("x");\nconst b = new C(7);\n`, 2) == "";
	const refused = checkWith(CLASS + `const c = new C(true);\n`, 2);
	assert refused.contains("No matching overload for the constructor of 'C'"), refused;
	const onlyString = checkWith(`class D {\n	constructor(a: string) {}\n	constructor(a: string | number) {}\n}\nconst d = new D(7);\n`, 1);
	assert onlyString.contains("No matching overload for the constructor of 'D'"), onlyString;
	const arity = checkWith(CLASS + `const e = new C("x", 1);\n`, 2);
	assert arity.contains("No matching overload for the constructor of 'C'"), arity;
}

test "a constructor signature the implementation does not hold is refused" {
	const text = checkWith(`class E {
	constructor(a: boolean) {}
	constructor(a: string | number) {}
}
const e = new E(true);
`, 1);
	assert text.contains("Overload signature for 'constructor' param 1 type 'boolean' not assignable to implementation param type 'number | string'"), text;
}

test "constructor signatures without an implementation, or with two, are refused" {
	const none = checkWith(`class F {\n	constructor(a: string) {}\n	constructor(a: number) {}\n}\n`, 2);
	assert none.contains("Overloaded constructor of 'F' has no implementation"), none;
	const two = checkWith(`class G {\n	constructor(a: string) {}\n	constructor(a: string | number) {}\n	constructor(a: string | number) {}\n}\n`, 1);
	assert two.contains("Overloaded constructor of 'G' has more than one implementation"), two;
}

test "an explicit abstract constructor is refused and a constructor of an abstract class is ordinary" {
	const explicit = checkWith(`class H {\n	constructor(a: string) {}\n}\n`, 0, 0);
	assert explicit.contains("'abstract' modifier can only appear on a class, method, or property declaration"), explicit;
	const abstractClass = checkWith(`abstract class I {\n	v: string = "";\n	constructor(a: string) {}\n	constructor(a: number) {}\n	constructor(a: string | number) { this.v = "x"; }\n}\nclass J extends I {}\n`, 2);
	assert !abstractClass.contains("abstract' modifier"), abstractClass;
}
