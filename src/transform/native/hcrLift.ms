// HCR State Lifting — rewrites module globals into a heap-allocated struct
// Gated behind --hcr flag. Without it, this file is never called.
//
// Before (standard):
//   let count: number = 0;
//   function increment(): void { count += 1; }
//
// After (HCR):
//   @emit("/*TYPESECTION*/typedef struct { double count; } _GlobalState;")
//   @emit("/*VARSECTION*/_GlobalState* _ms_gs;")
//   function increment(): void { (*_ms_gs).count += 1; }
//   @emit("void* _hcr_handover(void* old_state) { MS_HCR_HANDOVER(_GlobalState, ...) }")
//
// Codegen sees normal AST: MemberExpr, HiddenDeref, @emit. Zero HCR awareness needed.

import {
	Node, NodeKind, NodeFlag, DeclKind, SourceLocation, createNode,
	ProgramData, VariableDeclData, IdentifierData,
	FunctionDeclData, ExportDeclData, DecoratedDeclData,
	MacroInvocationData, ExprStmtData, StringLiteralData,
} from "../../ast/node";
import { Type, TypeKind, createObject, createPtr } from "../../checker/types";
import { Symbol, SymbolFlag, hasFlag } from "../../checker/symbol";
import { TransformContext } from "../context";
import { walkNode, mapChildren } from "../walker";
import {
	makeIdent, makeTypedIdent, makeMember, makeHiddenDeref, makeBinary,
	makeExprStmt, syntheticToken,
} from "../util";

// ===== Collected Global Info =====

interface HcrGlobal {
	name: string;
	declType: Type;
	initNode: Node;
}

// ===== Main Entry Point =====

export function liftHcrState(program: Node, ctx: TransformContext): Node {
	if (program === null || program.kind !== NodeKind.Program) return program;
	const pd = program.data as ProgramData;

	// Pass 1: Collect globals, replace VariableDecl with assignment ExprStmt
	const globals: HcrGlobal[] = [];
	const kept: Node[] = [];
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const stmt = pd.programStmts[i];
		const g = extractGlobal(stmt);
		if (g !== null) {
			globals.push(g);
			// Convert initializer to assignment statement (stays in ModuleInit)
			if (g.initNode !== null) {
				const lhs = makeIdent(g.name, stmt.location);
				if (g.declType !== null) lhs.nodeType = g.declType;
				const assign = makeBinary(lhs, "=", g.initNode, stmt.location);
				if (g.declType !== null) assign.nodeType = g.declType;
				kept.push(makeExprStmt(assign, stmt.location));
			}
		} else {
			kept.push(stmt);
		}
	}

	// No globals → nothing to lift
	if (globals.length === 0) {
		pd.programStmts = kept;
		return program;
	}

	// Build the GlobalState Object type (for MemberExpr type resolution)
	const fieldNames: string[] = [];
	const fieldTypes: Type[] = [];
	for (let i = 0; i < globals.length; i += 1) {
		fieldNames.push(globals[i].name);
		fieldTypes.push(globals[i].declType);
	}
	const gsType = createObject("_GlobalState", fieldNames, fieldTypes, true);
	const gsPtrType = createPtr(gsType);

	// Build a name set for O(1) lookup of globals
	const globalNames: string[] = [];
	for (let i = 0; i < globals.length; i += 1) {
		globalNames.push(globals[i].name);
	}

	// Pass 2: Rewrite all Identifier references to globals → (*_ms_gs).field
	const loc = program.location;
	for (let i = 0; i < kept.length; i += 1) {
		kept[i] = rewriteGlobalRefs(kept[i], globalNames, gsPtrType, loc);
	}

	// Pass 3: Synthesize HCR nodes via @emit
	const emitNodes: Node[] = [];

	// Include hcr.h
	emitNodes.push(makeEmitStmt("/*INCLUDESECTION*/#include \"hcr.h\"", loc));

	// GlobalState struct typedef
	let structDef = "/*TYPESECTION*/typedef struct {";
	for (let i = 0; i < globals.length; i += 1) {
		structDef = structDef + " " + typeToCStr(globals[i].declType) + " " + globals[i].name + ";";
	}
	structDef = structDef + " } _GlobalState;";
	emitNodes.push(makeEmitStmt(structDef, loc));

	// Global pointer variable
	emitNodes.push(makeEmitStmt("_GlobalState* _ms_gs;", loc));

	// Handover function — allocates GlobalState on first load, reuses on reload.
	// Init000 handles field initialization via assignments in program statements.
	// Dispatcher calls: _ms_gs = _hcr_handover(old); Init000();
	const handover = "__attribute__((visibility(\"default\"))) void* _hcr_handover(void* old_state) { "
		+ "if (old_state == NULL) { _ms_gs = (_GlobalState*)calloc(1, sizeof(_GlobalState)); return _ms_gs; } "
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

function extractGlobal(stmt: Node): HcrGlobal {
	if (stmt === null) return null as unknown as HcrGlobal;

	// Direct VariableDecl
	if (stmt.kind === NodeKind.VariableDecl) {
		return varDeclToGlobal(stmt);
	}

	// export const x = ...
	if (stmt.kind === NodeKind.ExportDecl) {
		const ed = stmt.data as ExportDeclData;
		if (ed.exportedDecl !== null && ed.exportedDecl.kind === NodeKind.VariableDecl) {
			return varDeclToGlobal(ed.exportedDecl);
		}
	}

	// @decorator const x = ...
	if (stmt.kind === NodeKind.DecoratedDecl) {
		const dd = stmt.data as DecoratedDeclData;
		if (dd.decoratedNode !== null && dd.decoratedNode.kind === NodeKind.VariableDecl) {
			return varDeclToGlobal(dd.decoratedNode);
		}
	}

	return null as unknown as HcrGlobal;
}

function varDeclToGlobal(node: Node): HcrGlobal {
	const d = node.data as VariableDeclData;
	// Skip _typeInfo vars (ORC runtime, should stay as globals)
	if (d.declName.length > 9 && d.declName.endsWith("_typeInfo")) {
		return null as unknown as HcrGlobal;
	}
	const t = node.nodeType !== null ? node.nodeType : null as unknown as Type;
	return { name: d.declName, declType: t, initNode: d.initializer };
}

// ===== Rewrite Global References =====
// Walks AST and replaces Identifier nodes that reference lifted globals
// with MemberExpr: (*_ms_gs).fieldName

function rewriteGlobalRefs(node: Node, globalNames: string[], gsPtrType: Type, loc: SourceLocation): Node {
	return walkNode(node, (n: Node): Node => {
		if (n.kind !== NodeKind.Identifier) return n;
		const d = n.data as IdentifierData;
		if (!isGlobalName(d.name, globalNames)) return n;

		// Build (*_ms_gs).fieldName
		const gsIdent = makeTypedIdent("_ms_gs", gsPtrType, loc);
		const deref = makeHiddenDeref(gsIdent, loc);
		const member = makeMember(deref, d.name, loc);
		// Preserve original type
		if (n.nodeType !== null) {
			member.nodeType = n.nodeType;
		}
		return member;
	});
}

function isGlobalName(name: string, globalNames: string[]): boolean {
	for (let i = 0; i < globalNames.length; i += 1) {
		if (globalNames[i] === name) return true;
	}
	return false;
}

// ===== @emit Helper =====
// Creates: ExprStmt(MacroInvocation("emit", [StringLiteral(code)]))

function makeEmitStmt(code: string, loc: SourceLocation): Node {
	const strNode = createNode(NodeKind.StringLiteral, { value: code }, syntheticToken(loc));
	const macroNode = createNode(NodeKind.MacroInvocation, { macroName: "emit", macroArgs: [strNode] }, syntheticToken(loc));
	return createNode(NodeKind.ExprStmt, { expr: macroNode }, syntheticToken(loc));
}

// ===== Type to C String =====
// Minimal mapping for GlobalState struct fields.

function typeToCStr(t: Type): string {
	if (t === null) return "void*";
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 => "double",
		TypeKind.String => "msString",
		TypeKind.Boolean => "MS_BOOL",
		TypeKind.Int8 => "int8_t",
		TypeKind.Int16 => "int16_t",
		TypeKind.Int32 => "int32_t",
		TypeKind.Int64 => "int64_t",
		TypeKind.Uint8 => "uint8_t",
		TypeKind.Uint16 => "uint16_t",
		TypeKind.Uint32 => "uint32_t",
		TypeKind.Uint64 => "uint64_t",
		TypeKind.Float32 => "float",
		TypeKind.Object => {
			if (t.typeName !== null && t.typeName.length > 0) {
				t.typeName
			} else {
				"void*"
			}
		},
		TypeKind.Array => {
			if (t.typeReturn !== null) {
				match (t.typeReturn.kind) {
					TypeKind.Number | TypeKind.Float64 => "msNumberArray",
					TypeKind.String => "msStringArray",
					TypeKind.Uint8 => "msUint8Array",
					_ => "msRefArray",
				}
			} else {
				"msRefArray"
			}
		},
		TypeKind.Class => {
			if (t.typeName !== null && t.typeName.length > 0) {
				t.typeName + "*"
			} else {
				"void*"
			}
		},
		TypeKind.Function => "msClosure",
		TypeKind.Ptr => "void*",
		_ => "void*",
	};
}
