import { checkOnlyEdited } from "../helpers";
import { Node, NodeKind, ProgramData, ClassDeclData, MethodDeclData } from "../../../ast/node";

function withOverride(source: string, owner: string, method: string): string {
	return checkOnlyEdited(source, (program: Node): void => {
		for (const stmt of (program.data as ProgramData).programStmts) {
			if (stmt.kind != NodeKind.ClassDecl) continue;
			const cd = stmt.data as ClassDeclData;
			if (cd.className != owner) continue;
			for (const member of cd.classBody) {
				if (member.kind != NodeKind.MethodDecl) continue;
				const md = member.data as MethodDeclData;
				if (md.methodName == method) md.methodFlags = md.methodFlags == "" ? "override" : `${md.methodFlags}|override`;
			}
		}
	}).errors.join("\n");
}

const NOT_IN_BASE = "This member cannot have an 'override' modifier because it is not declared in the base class 'A'";

test "an override modifier on a method the base class declares is accepted, also from a grandparent" {
	const base = "class A { f(): int32 { return 1; } }\n";
	assert withOverride(base + "class B extends A { f(): int32 { return 2; } }\n", "B", "f") == "";
	assert withOverride(base + "class B extends A { }\nclass C extends B { f(): int32 { return 3; } }\n", "C", "f") == "";
}

test "an override modifier on a method the base class does not declare is refused" {
	const text = withOverride("class A { f(): int32 { return 1; } }\nclass B extends A { g(): int32 { return 2; } }\n", "B", "g");
	assert text.contains(NOT_IN_BASE), text;
	const async = withOverride("class A { f(): int32 { return 1; } }\nclass B extends A { async g(): Promise<int32> { return 2; } }\n", "B", "g");
	assert async.contains(NOT_IN_BASE), async;
	const plain = withOverride("class A { f(): int32 { return 1; } }\nclass B extends A { g(): int32 { return 2; } }\n", "B", "f");
	assert !plain.contains("override"), plain;
}

test "an override modifier in a class with no base is refused" {
	const text = withOverride("class A { f(): int32 { return 1; } }\n", "A", "f");
	assert text.contains("This member cannot have an 'override' modifier because its containing class 'A' does not extend another class"), text;
}

test "an override modifier on a static method is checked against the static members of the base class" {
	const base = "class A { static f(): int32 { return 1; } g(): int32 { return 1; } }\n";
	assert withOverride(base + "class B extends A { static f(): int32 { return 2; } }\n", "B", "f") == "";
	assert withOverride(base + "class B extends A { }\nclass C extends B { static f(): int32 { return 3; } }\n", "C", "f") == "";
	const orphan = withOverride(base + "class B extends A { static h(): int32 { return 2; } }\n", "B", "h");
	assert orphan.contains(NOT_IN_BASE), orphan;
	const instanceOnly = withOverride(base + "class B extends A { static g(): int32 { return 2; } }\n", "B", "g");
	assert instanceOnly.contains(NOT_IN_BASE), instanceOnly;
	const noBase = withOverride("class A { static f(): int32 { return 1; } }\n", "A", "f");
	assert noBase.contains("does not extend another class"), noBase;
}
