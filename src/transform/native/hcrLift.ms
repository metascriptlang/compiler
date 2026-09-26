// HCR State Lifting — rewrites module globals into a heap-allocated struct
// Gated behind --hcr flag. Without it, this file is never called.
//
// Before (standard):
//   let count: number = 0;
//   function increment(): void { count += 1; }
//
// After (HCR):
//   struct _GlobalState { _struct_hash: uint64; count: number; }
//   @emit("_GlobalState* _ms_gs;")
//   function increment(): void { (*_ms_gs).count += 1; }
//   @emit("void* _hcr_handover(void* old_state) { MS_HCR_HANDOVER(_GlobalState, ...) }")
//
// Codegen sees normal AST: StructDecl, MemberExpr, HiddenDeref, @emit. Zero HCR awareness needed.

import {
	Node, NodeKind, SourceLocation, createNode,
	ProgramData, VariableDeclData, ExportDeclData, DecoratedDeclData, Symbol, Type, TypeKind } from "../../ast/node";
import { createStruct, createPtr, createPrimitive } from "../../checker/types";
import { TransformContext } from "../context";
import { djb2 } from "std/hash";
import { walkNode } from "../walker";
import { makeIdentResolved, makeTypedIdent, makeMember, makeHiddenDeref, makeBinary, makeExprStmt, syntheticToken } from "../util";
import { typeKey } from "../../codegen/c/types";

// ===== Collected Global Info =====

interface HcrGlobal {
	name: string;
	sym: Symbol;
	declType: Type;
	initNode: Node;
}

// ===== Main Entry Point =====

export function liftHcrState(program: Node, ctx: TransformContext): Node {
	if (program == null || program.kind != NodeKind.Program) return program;
	const pd = program.data as ProgramData;

	// Pass 1: Collect globals, replace VariableDecl with assignment ExprStmt
	const globals: HcrGlobal[] = [];
	const kept: Node[] = [];
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const stmt = pd.programStmts[i];
		const g = extractGlobal(stmt, ctx);
		if (g != null) {
			globals.push(g);
			// Convert initializer to assignment statement (stays in ModuleInit)
			if (g.initNode != null) {
				const lhs = makeIdentResolved(g.sym, stmt.location);
				if (g.declType != null) lhs.nodeType = g.declType;
				const assign = makeBinary(lhs, "=", g.initNode, stmt.location);
				if (g.declType != null) assign.nodeType = g.declType;
				kept.push(makeExprStmt(assign, stmt.location));
			}
		} else {
			kept.push(stmt);
		}
	}

	// No globals → nothing to lift
	if (globals.length == 0) {
		pd.programStmts = kept;
		return program;
	}

	const fieldNames: string[] = ["_struct_hash"];
	const fieldTypes: Type[] = [createPrimitive(TypeKind.Uint64)];
	for (let i = 0; i < globals.length; i += 1) {
		fieldNames.push(globals[i].name);
		fieldTypes.push(globals[i].declType);
	}
	const gsType = createStruct("_GlobalState", fieldNames, fieldTypes, true);
	const gsPtrType = createPtr(gsType);

	const globalSyms = new HashSet<Symbol>();
	for (const g of globals) globalSyms.add(g.sym);

	// Pass 2: Rewrite all Identifier references to globals → (*_ms_gs).field
	const loc = program.location;
	for (let i = 0; i < kept.length; i += 1) {
		kept[i] = rewriteGlobalRefs(kept[i], globalSyms, gsPtrType, loc);
	}

	const emitNodes: Node[] = [];
	const stateDecl = createNode(NodeKind.StructDecl, {
		interfaceName: "_GlobalState",
		interfaceFields: fieldNames,
		interfaceFieldTypes: [],
		interfaceExtends: [],
		nameLocation: loc,
	}, syntheticToken(loc));
	stateDecl.nodeType = gsType;
	emitNodes.push(stateDecl);

	// Structural hash of GlobalState layout (djb2 over field names + types)
	const structHash = computeStructHash(globals);
	emitNodes.push(makeEmitStmt("#define _MS_STRUCT_HASH " + structHash + "ULL", loc));

	// Global pointer variable
	emitNodes.push(makeEmitStmt("_GlobalState* _ms_gs;", loc));

	// Handover function — allocates GlobalState on first load, reuses on reload.
	// On reload, checks structural hash to detect incompatible layout changes.
	const handover = "MS_HCR_EXPORT void* _hcr_handover(void* old_state) { "
		+ "if (old_state == NULL) { _ms_gs = (_GlobalState*)calloc(1, sizeof(_GlobalState)); _ms_gs->_struct_hash = _MS_STRUCT_HASH; return _ms_gs; } "
		+ "if (((_GlobalState*)old_state)->_struct_hash != _MS_STRUCT_HASH) { "
		+ "fprintf(stderr, \"HCR: incompatible state layout change, full restart required\\n\"); return ((void*)0); } "
		+ "_ms_gs = (_GlobalState*)old_state; return _ms_gs; }";
	emitNodes.push(makeEmitStmt(handover, loc));

	// Assemble: emit nodes first, then kept statements
	const result: Node[] = [];
	for (let i = 0; i < emitNodes.length; i += 1) {
		result.push(emitNodes[i]);
	}
	for (let i = 0; i < kept.length; i += 1) {
		result.push(kept[i]);
	}
	pd.programStmts = result;
	return program;
}

// ===== Extract Global =====
// Returns HcrGlobal if the statement is a top-level variable declaration, null otherwise.
// Unwraps ExportDecl and DecoratedDecl wrappers.

function extractGlobal(stmt: Node, ctx: TransformContext): HcrGlobal {
	if (stmt == null) return null as unknown as HcrGlobal;

	// Direct VariableDecl
	if (stmt.kind == NodeKind.VariableDecl) {
		return varDeclToGlobal(stmt, ctx);
	}

	// export const x = ...
	if (stmt.kind == NodeKind.ExportDecl) {
		const ed = stmt.data as ExportDeclData;
		if (ed.exportedDecl != null && ed.exportedDecl.kind == NodeKind.VariableDecl) {
			return varDeclToGlobal(ed.exportedDecl, ctx);
		}
	}

	// @decorator const x = ...
	if (stmt.kind == NodeKind.DecoratedDecl) {
		const dd = stmt.data as DecoratedDeclData;
		if (dd.decoratedNode != null && dd.decoratedNode.kind == NodeKind.VariableDecl) {
			return varDeclToGlobal(dd.decoratedNode, ctx);
		}
	}

	return null as unknown as HcrGlobal;
}

function varDeclToGlobal(node: Node, ctx: TransformContext): HcrGlobal {
	const d = node.data as VariableDeclData;
	// Skip TypeInfo vars (ORC runtime, should stay as globals)
	if (d.declName.length > 8 && d.declName.endsWith("TypeInfo")) {
		return null as unknown as HcrGlobal;
	}
	const sym = node.resolvedSym;
	if (sym == null) {
		ctx.errors.push(`internal: HCR state lifting met module variable '${d.declName}' without a symbol`);
		return null as unknown as HcrGlobal;
	}
	const t = node.nodeType != null ? node.nodeType : null as unknown as Type;
	return { name: d.declName, sym, declType: t, initNode: d.initializer };
}

// ===== Rewrite Global References =====
// Walks AST and replaces Identifier nodes that reference lifted globals
// with MemberExpr: (*_ms_gs).fieldName

function rewriteGlobalRefs(node: Node, globalSyms: HashSet<Symbol>, gsPtrType: Type, loc: SourceLocation): Node {
	return walkNode(node, (n: Node): Node => {
		if (n.kind != NodeKind.Identifier || n.resolvedSym == null || !globalSyms.has(n.resolvedSym)) return n;
		const sym = n.resolvedSym;

		// Build (*_ms_gs).fieldName
		const gsIdent = makeTypedIdent("_ms_gs", gsPtrType, loc);
		const deref = makeHiddenDeref(gsIdent, loc);
		const member = makeMember(deref, sym.name, loc);
		// Preserve original type
		if (n.nodeType != null) {
			member.nodeType = n.nodeType;
		}
		return member;
	});
}

// ===== @emit Helper =====
// Creates: ExprStmt(MacroInvocation("emit", [StringLiteral(code)]))

function makeEmitStmt(code: string, loc: SourceLocation): Node {
	const strNode = createNode(NodeKind.StringLiteral, { value: code }, syntheticToken(loc));
	const macroNode = createNode(NodeKind.MacroInvocation, { macroName: "emit", macroArgs: [strNode], macroHasParens: true }, syntheticToken(loc));
	return createNode(NodeKind.ExprStmt, { expr: macroNode }, syntheticToken(loc));
}

// ===== Structural Hash =====
// djb2 hash over field "name:typeKey;" pairs. Detects layout changes at reload time.

function computeStructHash(globals: HcrGlobal[]): int64 {
	let key = "";
	for (const g of globals) {
		key = key + g.name + ":" + typeKey(g.declType) + ";";
	}
	return djb2(key);
}
