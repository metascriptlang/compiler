import { Node, NodeKind, NodeFlag, IfStmtData, ExprStmtData, CallExprData, IdentifierData } from "../../ast/node";
import { walkNode } from "../walker";
import { lex } from "../../lexer/lexer";
import { createState } from "../../parser/cursor";
import { parseProgram } from "../../parser/statements/core";

export function pickWhenRaiser(program: Node, raiserBranch: boolean): Node {
	return walkNode(program, (n: Node): Node => {
		if (n.kind != NodeKind.IfStmt || !n.flags.has(NodeFlag.WhenRaiser)) return n;
		const d = n.data as IfStmtData;
		return raiserBranch ? d.consequent : d.alternate as Node;
	});
}

function calleeNamesIn(program: Node): string[] {
	const names: string[] = [];
	walkNode(program, (n: Node): Node => {
		if (n.kind == NodeKind.ExprStmt) {
			const e = (n.data as ExprStmtData).expr;
			if (e.kind == NodeKind.CallExpr) {
				const callee = (e.data as CallExprData).callee;
				if (callee.kind == NodeKind.Identifier) names.push((callee.data as IdentifierData).name);
			}
		}
		return n;
	});
	return names;
}

function parsed(src: string): { program: Node, errors: string[] } {
	const lr = lex(src);
	if (!lr.ok) throw new Error(lr.error);
	const state = createState(lr.value);
	const program = parseProgram(state);
	if (!program.ok) throw new Error(program.error);
	return { program: program.value, errors: state.errors };
}

function firstError(src: string): string {
	const errors = parsed(src).errors;
	return errors.length > 0 ? errors[0] : "";
}

test "a body's when (raiser) keeps both blocks until a backend picks one" {
	const src = "function f(): void { when (raiser) { vm(); } else { other(); } after(); }";
	assert calleeNamesIn(parsed(src).program).join(",") == "vm,other,after";
	assert calleeNamesIn(pickWhenRaiser(parsed(src).program, true)).join(",") == "vm,after";
	assert calleeNamesIn(pickWhenRaiser(parsed(src).program, false)).join(",") == "other,after";
}

test "a body's when (raiser) needs one else and no other flag beside raiser" {
	assert firstError("function f(): void { when (raiser) { vm(); } }").includes("exactly one else");
	assert firstError("function f(): void { when (raiser) { vm(); } else when (js) { a(); } else { b(); } }").includes("exactly one else");
	assert firstError("function f(): void { when (js || raiser) { vm(); } else { b(); } }").includes("stands alone");
	assert parsed("when (js || raiser) { vm(); } else { b(); }").errors.length == 0;
	assert parsed("when (raiser) { vm(); }").errors.length == 0;
}
