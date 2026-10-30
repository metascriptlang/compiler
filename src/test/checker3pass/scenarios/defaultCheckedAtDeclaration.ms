import { checkOnly, findFnDecl, findFirstByKind } from "../helpers";
import { NodeKind, NodeFlag, FunctionDeclData, MethodDeclData, Node, TypeKind } from "../../../ast/node";
import { forEachChild } from "../../../ast/visitor";
import { hoistsOfDefault } from "../../../checker/context";

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

function undeclaredBoundReads(stored: Node): number {
	const declared: Node[] = hoistsOfDefault(stored);
	let undeclared = 0;
	const visit = (n: Node): void => {
		if (n.kind == NodeKind.VariableDecl) declared.push(n);
		forEachChild(n, visit);
	};
	forEachChild(stored, visit);
	const check = (n: Node): void => {
		if (n.kind == NodeKind.Identifier && n.flags.has(NodeFlag.BoundSym)) {
			let found = false;
			for (const d of declared) { if (d == n.resolvedSym!.declNode) found = true; }
			if (!found) undeclared += 1;
		}
		forEachChild(n, check);
	};
	check(stored);
	return undeclared;
}

const hoistingDefaults = "function inner(a: string, b: string = a + \"!\"): string { return b; }\nfunction make(): string { return \"m\"; }\n";

test "a function default that binds a temporary carries the declaration of it" {
	const result = checkOnly(hoistingDefaults + "function f(s: string = inner(make())): string { return s; }\nconst r = f();");
	assert result.errors.length == 0;
	const stored = (findFnDecl(result.program, "f").data as FunctionDeclData).fnDefaults[0];
	assert hoistsOfDefault(stored).length == 1;
	assert undeclaredBoundReads(stored) == 0;
}

test "a method default that binds a temporary carries the declaration of it" {
	const result = checkOnly(hoistingDefaults + "class C { m(s: string = inner(make())): string { return s; } }\nconst r = new C().m();");
	assert result.errors.length == 0;
	const stored = (findFirstByKind(result.program, NodeKind.MethodDecl).data as MethodDeclData).methodDefaults.filter((d: Node) => d != null)[0];
	assert hoistsOfDefault(stored).length == 1;
	assert undeclaredBoundReads(stored) == 0;
}

test "a default that binds nothing carries no declaration" {
	const result = checkOnly("function f(x: float64 = 1): float64 { return x; }\nconst r = f();");
	const stored = (findFnDecl(result.program, "f").data as FunctionDeclData).fnDefaults[0];
	assert hoistsOfDefault(stored).length == 0;
}
