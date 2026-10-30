import { checkOnly, findFnDecl, findFirstByKind } from "../helpers";
import { NodeKind, FunctionDeclData, MethodDeclData, Node, TypeKind } from "../../../ast/node";

function typedDefaults(defaults: Node[]): TypeKind[] {
	const kinds: TypeKind[] = [];
	for (const def of defaults) {
		if (def == null) continue;
		kinds.push(def.nodeType != null ? def.nodeType.kind : TypeKind.None);
	}
	return kinds;
}

test "a function parameter default is checked and fitted where it is declared" {
	const result = checkOnly("function f(x: float64 = 1, y: string = \"a\"): float64 { return x; }\nconst r = f();");
	assert result.errors.length == 0;
	const kinds = typedDefaults((findFnDecl(result.program, "f").data as FunctionDeclData).fnDefaults);
	assert kinds.length == 2;
	assert kinds[0] == TypeKind.Float64;
	assert kinds[1] == TypeKind.String;
}

test "a method parameter default is checked and fitted where it is declared" {
	const result = checkOnly("class C { m(x: float64 = 1): float64 { return x; } }\nconst r = new C().m();");
	assert result.errors.length == 0;
	const method = findFirstByKind(result.program, NodeKind.MethodDecl);
	const kinds = typedDefaults((method.data as MethodDeclData).methodDefaults);
	assert kinds.length == 1;
	assert kinds[0] == TypeKind.Float64;
}

test "a refused default is reported once however many calls omit it" {
	const result = checkOnly("function g(x: int32 = \"s\"): int32 { return x; }\nconst a = g();\nconst b = g();");
	assert result.errors.length == 1;
}
