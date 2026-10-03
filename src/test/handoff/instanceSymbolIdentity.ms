import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { ExportRegistry } from "../../checker/context";
import { Node, NodeKind, Symbol, NewExprData, MemberExprData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { forEachChild } from "../../ast/visitor";
import { resetBuildState } from "../../compiler/buildSession";

function checkedProgram(source: string): Node {
	resetBuildState();
	const prelude = preludeContextFor("", ".cms");
	const pr = parseSource(source);
	if (!pr.ok) throw new Error("internal: test source does not parse");
	checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	return pr.value;
}

function instanceSyms(n: Node | null, out: Symbol[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.NewExpr) {
		const callee = (n.data as NewExprData).newCallee;
		if (callee.resolvedSym != null && callee.resolvedSym.instantiatedFrom != null) out.push(callee.resolvedSym);
	}
	forEachChild(n, (c: Node): void => { instanceSyms(c, out); });
}

function toStringSyms(n: Node | null, out: Symbol[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.MemberExpr && (n.data as MemberExprData).property == "toString" && n.resolvedSym != null) out.push(n.resolvedSym);
	forEachChild(n, (c: Node): void => { toStringSyms(c, out); });
}

test "instanceSymbolIdentity: the instance of a generic class carries its declaration and an item" {
	const sources = [
		"class UserBox<T> { v: T; constructor(v: T) { this.v = v; } }\nfunction userMake(): UserBox<number> { return new UserBox<number>(1); }",
		"class UserPair<A, B> { a: A; b: B; constructor(a: A, b: B) { this.a = a; this.b = b; } }\nfunction userMake(): UserPair<string, boolean> { return new UserPair<string, boolean>(\"s\", true); }",
	];
	for (const source of sources) {
		const found: Symbol[] = [];
		instanceSyms(checkedProgram(source), found);
		assert found.length == 1, source;
		assert found[0].item > 0, source;
		assert found[0].declNode != null && found[0].declNode.kind == NodeKind.ClassDecl, source;
	}
}

test "instanceSymbolIdentity: the compiler-provided toString carries an item on a class and on a struct" {
	const sources = [
		"class UserPoint { x: number = 1; }\nfunction userShow(p: UserPoint): string { return p.toString(); }",
		"interface UserShape { w: number; }\nfunction userShow(s: UserShape): string { return s.toString(); }",
	];
	for (const source of sources) {
		const found: Symbol[] = [];
		toStringSyms(checkedProgram(source), found);
		assert found.length == 1, source;
		assert found[0].item > 0, source;
	}
}
