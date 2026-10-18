import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { CheckerContext, ExportRegistry } from "../../checker/context";
import { Node, NodeKind, SymbolKind, MemberExprData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { resetBuildState } from "../../compiler/buildSession";
import { forEachChild } from "../../ast/visitor";

function checkedUnit(source: string): { program: Node, ctx: CheckerContext } {
	resetBuildState();
	const prelude = preludeContextFor("", ".cms");
	const pr = parseSource(source);
	if (!pr.ok) throw new Error("internal: test source does not parse");
	const ctx = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	return { program: pr.value, ctx };
}

function errorsOf(ctx: CheckerContext): string[] {
	const messages: string[] = [];
	for (const e of ctx.errors) messages.push(e.message);
	return messages;
}

function memberAccesses(node: Node, property: string, found: Node[]): Node[] {
	if (node.kind == NodeKind.MemberExpr && (node.data as MemberExprData).property == property) found.push(node);
	forEachChild(node, (child: Node): void => { memberAccesses(child, property, found); });
	return found;
}

test "memberBinding: a static call finds the static method the class declares" {
	const unit = checkedUnit(`class Box { static make(): string { return "static"; } }
const s = Box.make();
`);
	assert errorsOf(unit.ctx).length == 0, errorsOf(unit.ctx).join("\n");
}

test "memberBinding: a static call finds no module function spelled Class_member" {
	const unit = checkedUnit(`class Box { size: int32 = 3; }
function Box_make(): string { return "free function"; }
const s = Box.make();
`);
	const messages = errorsOf(unit.ctx);
	assert messages.length == 1 && messages[0].contains("'make'"), messages.join("\n");
}

test "memberBinding: a class field access binds the field, not a module function spelled Type_field" {
	const unit = checkedUnit(`class Box { size: int32 = 3; }
function Box_size(): int32 { return 99; }
const b = new Box();
const s = b.size;
`);
	const accesses = memberAccesses(unit.program, "size", []);
	assert accesses.length == 1;
	const sym = accesses[0].resolvedSym;
	assert sym != null && sym.symbolKind == SymbolKind.Property, sym != null ? `${sym.name} kind ${sym.symbolKind}` : "no symbol";
}

test "memberBinding: an interface field access binds the field, not a module variable spelled Type_field" {
	const unit = checkedUnit(`interface Box { size: int32; }
const Box_size: int32 = 99;
const b: Box = { size: 3 };
const s = b.size;
`);
	const accesses = memberAccesses(unit.program, "size", []);
	assert accesses.length == 1;
	const sym = accesses[0].resolvedSym;
	assert sym != null && sym.symbolKind == SymbolKind.Property, sym != null ? `${sym.name} kind ${sym.symbolKind}` : "no symbol";
}
