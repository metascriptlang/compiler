// A module reached only through import() whose body has a top-level await evaluates as an
// async routine: the body moves into `async function $moduleBody()`, the module's own
// bindings stay module globals assigned from inside it, and the module init hands the
// routine's promise to the module evaluator (runtime/promise/moduleEval.c).

import {
	Node, NodeKind, NodeFlag, SymbolKind,
	ProgramData, ExportDeclData, DecoratedDeclData, VariableDeclData,
} from "../../ast/node";
import { TransformContext, mintSym } from "../context";
import { makeFnDecl, makeBlock, makeExprStmt, makeAssign, makeCall, makeTypedIdentResolved, runtimeRef } from "../util";
import { createFunction, createPromise, voidType } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { addError } from "../../checker/context";

function declarationOf(stmt: Node): Node {
	if (stmt.kind == NodeKind.ExportDecl) return declarationOf((stmt.data as ExportDeclData).exportedDecl);
	if (stmt.kind == NodeKind.DecoratedDecl) return declarationOf((stmt.data as DecoratedDeclData).decoratedNode);
	return stmt;
}

function staysDeclared(decl: Node): boolean {
	return match (decl.kind) {
		NodeKind.FunctionDecl | NodeKind.ClassDecl | NodeKind.ActorDecl | NodeKind.EnumDecl | NodeKind.ImportDecl
			| NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.TypeAliasDecl | NodeKind.ExternDecl
			| NodeKind.MacroDecl | NodeKind.ComptimeBlock | NodeKind.TypeAnnotation | NodeKind.TestDecl | NodeKind.PropertyDecl => true,
		_ => false,
	};
}

function isModuleBinding(decl: Node): boolean {
	return decl.kind == NodeKind.VariableDecl && decl.resolvedSym != null && hasFlag(decl.resolvedSym, SymbolFlag.Global);
}

export function lowerAsyncModuleBody(program: Node, ctx: TransformContext): Node {
	const pd = program.data as ProgramData;
	const kept: Node[] = [];
	const body: Node[] = [];
	for (const stmt of pd.programStmts) {
		const decl = declarationOf(stmt);
		if (stmt.kind == NodeKind.ExportDecl && stmt.flags.has(NodeFlag.ExportDefault) && !staysDeclared(decl)) {
			addError(ctx.checkerCtx, "export default of an expression in a module with a top-level await that only import() reaches is not supported; export a named binding", stmt.location.line, stmt.location.column);
			continue;
		}
		if (staysDeclared(decl)) {
			kept.push(stmt);
		} else if (isModuleBinding(decl)) {
			kept.push(stmt);
			const d = decl.data as VariableDeclData;
			if (d.initializer != null) {
				const sym = decl.resolvedSym!;
				const target = makeTypedIdentResolved(sym, sym.symbolType, decl.location);
				body.push(makeExprStmt(makeAssign(target, d.initializer, decl.location), decl.location));
				d.initializer = null as unknown as Node;
			}
		} else {
			body.push(stmt);
		}
	}
	const loc = program.location;
	const fnType = createFunction([], [], createPromise(voidType()));
	const fnSym = mintSym(ctx, SymbolKind.Function, "$moduleBody", fnType);
	const fn = makeFnDecl(fnSym.name, [], [], makeBlock(body, loc), "async", "void", loc);
	fn.nodeType = fnType;
	fn.resolvedSym = fnSym;
	fnSym.declNode = fn;
	const start = makeCall(makeTypedIdentResolved(fnSym, fnType, loc), [], loc);
	start.nodeType = createPromise(voidType());
	const handOff = makeCall(runtimeRef("msModuleAsyncBody", loc), [start], loc);
	handOff.nodeType = voidType();
	kept.push(fn);
	kept.push(makeExprStmt(handOff, loc));
	pd.programStmts = kept;
	return program;
}
