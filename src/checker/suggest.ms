// Suggest — LSP intelligence layer
//
// Pure computation: typeToString, findNodeAtPosition, getSymbolAtCursor,
// formatHover, collectDiagnostics. No I/O, no protocol knowledge.
// Called by src/lsp/handlers.ms.

import { Node, NodeKind, SourceLocation, ProgramData, DeclKind,
	IdentifierData, MemberExprData, CallExprData,
	BinaryExprData, UnaryExprData, VariableDeclData,
	FunctionDeclData, IfStmtData, WhileStmtData, ForStmtData,
	ForOfStmtData, BlockStmtData, ExprStmtData, ReturnStmtData,
	ArrayLiteralData, ObjectLiteralData, ConditionalExprData,
	ArrowFunctionData, ArrayAccessData, MatchExprData, MatchCaseData,
	TryCatchStmtData, TryExprData, ClassDeclData, InterfaceDeclData, EnumDeclData,
	TypeAliasDeclData, ExportDeclData, ImportDeclData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { Type, TypeKind, typeNameOf, getProperty,
	numberType, stringType, booleanType, voidType, nullType,
	unknownType, neverType, errorType } from "./types";
import { Symbol, SymbolKind, SymbolTable, Scope, lookupSymbol, makeSymbol, hasFlag, SymbolFlag } from "./symbol";
import { CheckerContext, findAllExtensionsByName, filterExtsByReceiverType, getExtFnType, stripReceiverParam } from "./context";
import { sliceStr, charAt } from "../utils/string";
import { checkProgram } from "./checkPass";
import { parseSource } from "../parser/statements/validation";
// Import parseProgram to trigger callback registration (side-effect import)
import { parseProgram } from "../parser/statements/core";

// ===== Data Types =====

export interface SgSuggest {
	name: string;
	kind: SymbolKind;
	symType: Type;
	location: SourceLocation;
	prefixScore: number;   // 0=None, 1=Substr, 2=Prefix
	scopeDepth: number;    // 0=innermost, higher=outer
	contextFit: boolean;   // type-context match
	isExported: boolean;   // from sym.isExported
	isMutable: boolean;    // from sym.isMutable (let vs const)
}

export interface SgDiagnostic {
	message: string;
	line: number;
	column: number;
	severity: number;  // 1=Error, 2=Warning
}

export enum SgCompletionKind {
	Identifier,
	MemberAccess,
	TypeAnnotation,
}

export interface SgDocumentSymbol {
	name: string;
	kind: SymbolKind;
	location: SourceLocation;
	detail: string;    // type signature for outline view
	isMutable: boolean; // let/var vs const — for Constant(14) vs Variable(13) icon
}

export interface SgSignatureInfo {
	label: string;
	paramLabels: string[];
}

// ===== sgTypeToString — full recursive type formatting =====

export function sgTypeToString(t: Type): string {
	if (t === null) return "unknown";

	const prim = match (t.kind) {
		TypeKind.Number => "number", TypeKind.String => "string",
		TypeKind.Boolean => "boolean", TypeKind.Void => "void",
		TypeKind.Null => "null", TypeKind.Unknown => "unknown",
		TypeKind.Never => "never", TypeKind.Error => "error",
		TypeKind.Int8 => "int8", TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32", TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8", TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32", TypeKind.Uint64 => "uint64",
		TypeKind.Float32 => "float32", TypeKind.Float64 => "float64",
		_ => "",
	};
	if (prim.length > 0) return prim;

	if (t.kind === TypeKind.Array) {
		const elem = sgTypeToString(t.typeReturn);
		return elem + "[]";
	}

	if (t.kind === TypeKind.Struct) {
		if (t.typeName.length > 0) return t.typeName;
		// Anonymous object: { key: type, ... }
		let result = "{ ";
		for (let i = 0; i < t.typeNames.length; i = i + 1) {
			if (i > 0) result = result + ", ";
			result = result + t.typeNames[i] + ": ";
			if (i < t.typeChildren.length) {
				result = result + sgTypeToString(t.typeChildren[i]);
			}
		}
		result = result + " }";
		return result;
	}

	if (t.kind === TypeKind.Function) {
		let result = "(";
		for (let i = 0; i < t.typeChildren.length; i = i + 1) {
			if (i > 0) result = result + ", ";
			if (i < t.typeNames.length && t.typeNames[i].length > 0) {
				result = result + t.typeNames[i] + ": ";
			}
			result = result + sgTypeToString(t.typeChildren[i]);
		}
		result = result + ") => " + sgTypeToString(t.typeReturn);
		return result;
	}

	if (t.kind === TypeKind.Enum) return t.typeName;

	if (t.kind === TypeKind.Union) {
		let result = "";
		for (let i = 0; i < t.typeChildren.length; i = i + 1) {
			if (i > 0) result = result + " | ";
			result = result + sgTypeToString(t.typeChildren[i]);
		}
		return result;
	}

	if (t.kind === TypeKind.Tuple) {
		let result = "[";
		for (let i = 0; i < t.typeChildren.length; i = i + 1) {
			if (i > 0) result = result + ", ";
			result = result + sgTypeToString(t.typeChildren[i]);
		}
		result = result + "]";
		return result;
	}

	if (t.kind === TypeKind.Result) {
		const ok = sgTypeToString(t.typeReturn);
		const err = sgTypeToString(t.typeExtra);
		return "Result<" + ok + ", " + err + ">";
	}

	if (t.kind === TypeKind.Map) {
		const key = sgTypeToString(t.typeReturn);
		const val = sgTypeToString(t.typeExtra);
		return "Map<" + key + ", " + val + ">";
	}

	if (t.kind === TypeKind.Set) {
		return "Set<" + sgTypeToString(t.typeReturn) + ">";
	}

	if (t.kind === TypeKind.Ref) {
		return "ref " + sgTypeToString(t.typeReturn);
	}

	if (t.kind === TypeKind.Ptr) {
		return "ptr " + sgTypeToString(t.typeReturn);
	}

	if (t.kind === TypeKind.Distinct) {
		return "distinct " + sgTypeToString(t.typeReturn);
	}

	if (t.kind === TypeKind.GenericParam) return t.typeName;

	if (t.kind === TypeKind.GenericInstance) {
		let result = sgTypeToString(t.typeExtra);
		result = result + "<";
		for (let i = 0; i < t.typeChildren.length; i = i + 1) {
			if (i > 0) result = result + ", ";
			result = result + sgTypeToString(t.typeChildren[i]);
		}
		result = result + ">";
		return result;
	}

	if (t.kind === TypeKind.TypeReference) return t.typeName;

	return "unknown";
}

// ===== sgFindNodeAtPosition — walk AST to find node at cursor =====
//
// Reference pattern: check exact column span for node tracking.
// We can't use forEachChild (causes hangs on large files), so manual walk.
// Key insight from standard reference patterns: don't prune by column on container nodes — child nodes
// (e.g. MemberExpr condition in IfStmt) can have column > parent's column.

function nodeContains(node: Node, line: number, col: number): boolean {
	if (node === null) return false;
	const loc = node.location;
	if (loc === null) return false;
	if (loc.line > line) return false;
	if (loc.line === line && loc.column > col) return false;
	return true;
}

function sgTokenLen(node: Node): number {
	if (node.kind === NodeKind.Identifier) return (node.data as IdentifierData).name.length;
	if (node.kind === NodeKind.NumberLiteral) return 1;
	if (node.kind === NodeKind.StringLiteral) return 1;
	if (node.kind === NodeKind.BooleanLiteral) return 4;
	if (node.kind === NodeKind.NullLiteral) return 4;
	return 0;
}

// Reference: leaf node at exact cursor position
function isTracked(node: Node, line: number, col: number): boolean {
	if (node === null) return false;
	const loc = node.location;
	if (loc.line !== line) return false;
	const len = sgTokenLen(node);
	if (len > 0) return col >= loc.column && col < loc.column + len;
	return false;
}

function sgFindInChildren(children: Node[], line: number, col: number): Node {
	for (let i = children.length - 1; i >= 0; i = i - 1) {
		const child = children[i];
		if (child !== null && child.location.line <= line) {
			const deeper = sgFindNodeAtPosition(child, line, col);
			if (deeper !== null) return deeper;
		}
	}
	return null as unknown as Node;
}

// Try child with standard containment (start position check)
function sgTryChildLine(child: Node, line: number, col: number): Node {
	if (child === null) return null as unknown as Node;
	if (!nodeContains(child, line, col)) return null as unknown as Node;
	return sgFindNodeAtPosition(child, line, col);
}

// Try child of a statement node — line-only containment (no column check).
// Statement children (IfStmt condition, etc.) can start at any column.
function sgTryStmtChild(child: Node, line: number, col: number): Node {
	if (child === null) return null as unknown as Node;
	const loc = child.location;
	if (loc === null) return null as unknown as Node;
	if (loc.line > line) return null as unknown as Node;
	return sgFindNodeAtPosition(child, line, col);
}

export function sgFindNodeAtPosition(program: Node, line: number, col: number): Node {
	if (program === null) return null as unknown as Node;
	// Line-only guard: don't reject by column here — child nodes may start
	// at different columns (MemberExpr loc is at dot, not at object).
	// Leaf isTracked handles exact column matching.
	const pLoc = program.location;
	if (pLoc === null) return null as unknown as Node;
	if (pLoc.line > line) return null as unknown as Node;

	// Leaf nodes — use isTracked (exact column span)
	if (isTracked(program, line, col)) return program;
	// Leaf nodes that didn't match — reject
	if (program.kind === NodeKind.Identifier
		|| program.kind === NodeKind.NumberLiteral
		|| program.kind === NodeKind.StringLiteral
		|| program.kind === NodeKind.BooleanLiteral
		|| program.kind === NodeKind.NullLiteral) return null as unknown as Node;

	// Container nodes — recurse into children
	if (program.kind === NodeKind.Program) {
		return sgFindInChildren((program.data as ProgramData).programStmts, line, col);
	}
	if (program.kind === NodeKind.BlockStmt) {
		return sgFindInChildren((program.data as BlockStmtData).statements, line, col);
	}
	if (program.kind === NodeKind.VariableDecl) {
		const vd = program.data as VariableDeclData;
		const f = sgTryStmtChild(vd.initializer, line, col);
		if (f !== null) return f;
		// No child matched — cursor is on declaration name or type annotation
		if (pLoc.line === line) return program;
		return null as unknown as Node;
	}
	if (program.kind === NodeKind.ExprStmt) {
		return sgTryStmtChild((program.data as ExprStmtData).expr, line, col);
	}
	if (program.kind === NodeKind.ReturnStmt) {
		return sgTryStmtChild((program.data as ReturnStmtData).argument, line, col);
	}
	if (program.kind === NodeKind.BinaryExpr) {
		const bd = program.data as BinaryExprData;
		const r = sgTryStmtChild(bd.right, line, col);
		if (r !== null) return r;
		return sgTryStmtChild(bd.left, line, col);
	}
	if (program.kind === NodeKind.CallExpr) {
		const cd = program.data as CallExprData;
		for (let i = cd.arguments.length - 1; i >= 0; i = i - 1) {
			const f = sgTryStmtChild(cd.arguments[i], line, col);
			if (f !== null) return f;
		}
		return sgTryStmtChild(cd.callee, line, col);
	}
	if (program.kind === NodeKind.MemberExpr) {
		const md = program.data as MemberExprData;
		// Object child can start before the dot — use line-only
		const f = sgTryStmtChild(md.object, line, col);
		if (f !== null) return f;
		// Property name: not a child node, synthesize match
		if (program.location.line === line) {
			// MemberExpr location is at the dot. Property starts at dot+1.
			const propCol = program.location.column + 1;
			if (col >= propCol && col < propCol + md.property.length) return program;
		}
		return null as unknown as Node;
	}
	if (program.kind === NodeKind.IfStmt) {
		const id = program.data as IfStmtData;
		// Statement children — use line-only containment (condition column may differ)
		const c = sgTryStmtChild(id.condition, line, col);
		if (c !== null) return c;
		const t = sgTryStmtChild(id.consequent, line, col);
		if (t !== null) return t;
		return sgTryStmtChild(id.alternate, line, col);
	}
	if (program.kind === NodeKind.WhileStmt) {
		const wd = program.data as WhileStmtData;
		const c = sgTryStmtChild(wd.whileCondition, line, col);
		if (c !== null) return c;
		return sgTryStmtChild(wd.whileBody, line, col);
	}
	if (program.kind === NodeKind.FunctionDecl) {
		const fd = program.data as FunctionDeclData;
		for (let i = 0; i < fd.params.length; i = i + 1) {
			const f = sgTryStmtChild(fd.params[i], line, col);
			if (f !== null) return f;
		}
		const fnB = sgTryStmtChild(fd.fnBody, line, col);
		if (fnB !== null) return fnB;
		// Cursor on function name
		if (pLoc.line === line) return program;
		return null as unknown as Node;
	}
	if (program.kind === NodeKind.ArrowFunction) {
		const af = program.data as ArrowFunctionData;
		return sgTryStmtChild(af.arrowBody, line, col);
	}
	if (program.kind === NodeKind.ConditionalExpr) {
		const cd = program.data as ConditionalExprData;
		const c = sgTryStmtChild(cd.ternaryCondition, line, col);
		if (c !== null) return c;
		const t = sgTryStmtChild(cd.ternaryConsequent, line, col);
		if (t !== null) return t;
		return sgTryStmtChild(cd.ternaryAlternate, line, col);
	}
	if (program.kind === NodeKind.UnaryExpr) {
		return sgTryStmtChild((program.data as UnaryExprData).operand, line, col);
	}
	if (program.kind === NodeKind.ArrayAccess) {
		const ad = program.data as ArrayAccessData;
		const i = sgTryStmtChild(ad.index, line, col);
		if (i !== null) return i;
		return sgTryStmtChild(ad.array, line, col);
	}
	if (program.kind === NodeKind.ArrayLiteral) {
		return sgFindInChildren((program.data as ArrayLiteralData).elements, line, col);
	}
	if (program.kind === NodeKind.ObjectLiteral) {
		return sgFindInChildren((program.data as ObjectLiteralData).properties, line, col);
	}
	if (program.kind === NodeKind.ForOfStmt) {
		const fod = program.data as ForOfStmtData;
		const b = sgTryStmtChild(fod.forOfBody, line, col);
		if (b !== null) return b;
		return sgTryStmtChild(fod.forOfIterable, line, col);
	}
	if (program.kind === NodeKind.ForStmt) {
		const fs = program.data as ForStmtData;
		const b = sgTryStmtChild(fs.forBody, line, col);
		if (b !== null) return b;
		const u = sgTryStmtChild(fs.forUpdate, line, col);
		if (u !== null) return u;
		const t = sgTryStmtChild(fs.forTest, line, col);
		if (t !== null) return t;
		return sgTryStmtChild(fs.forInit, line, col);
	}
	if (program.kind === NodeKind.TryCatchStmt) {
		const tc = program.data as TryCatchStmtData;
		const t = sgTryStmtChild(tc.tryBlock, line, col);
		if (t !== null) return t;
		const c = sgTryStmtChild(tc.catchBlock, line, col);
		if (c !== null) return c;
		return sgTryStmtChild(tc.finallyBlock, line, col);
	}
	if (program.kind === NodeKind.MatchExpr) {
		const me = program.data as MatchExprData;
		const d = sgTryStmtChild(me.matchDiscriminant, line, col);
		if (d !== null) return d;
		return sgFindInChildren(me.matchCases, line, col);
	}
	if (program.kind === NodeKind.MatchCase) {
		const mc = program.data as MatchCaseData;
		const b = sgTryStmtChild(mc.caseBody, line, col);
		if (b !== null) return b;
		return sgFindInChildren(mc.casePatterns, line, col);
	}
	if (program.kind === NodeKind.ClassDecl) {
		const cd = program.data as ClassDeclData;
		return sgFindInChildren(cd.classBody, line, col);
	}
	if (program.kind === NodeKind.TryExpr) {
		const te = program.data as TryExprData;
		return sgTryStmtChild(te.tryExpr, line, col);
	}
	if (program.kind === NodeKind.ExportDecl) {
		return sgTryStmtChild((program.data as ExportDeclData).exportedDecl, line, col);
	}

	// Fallback: no children found
	return null as unknown as Node;
}

// ===== sgGetSymbolAtCursor — resolve symbol at cursor position =====

// Build SgSuggest from a Symbol.
function sgSuggestFromSym(sym: Symbol): SgSuggest {
	return {
		name: sym.name, kind: sym.symbolKind, symType: sym.symbolType,
		location: sym.location, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: hasFlag(sym, SymbolFlag.Exported), isMutable: hasFlag(sym, SymbolFlag.Mutable),
	};
}

export function sgGetSymbolAtCursor(ctx: CheckerContext, program: Node, line: number, col: number): SgSuggest {
	const node = sgFindNodeAtPosition(program, line, col);
	if (node === null) return null as unknown as SgSuggest;

	// Checker-stamped resolvedSym is always authoritative
	if (node.resolvedSym !== null) return sgSuggestFromSym(node.resolvedSym);

	if (node.kind === NodeKind.Identifier) {
		const id = node.data as IdentifierData;
		const sym = lookupSymbol(ctx.table, id.name);
		if (sym !== null) return sgSuggestFromSym(sym);
	}

	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		const sym = lookupSymbol(ctx.table, vd.declName);
		if (sym !== null) return sgSuggestFromSym(sym);
	}

	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		const sym = lookupSymbol(ctx.table, fd.fnName);
		if (sym !== null) return sgSuggestFromSym(sym);
	}

	// MemberExpr: cursor on property name (e.g. p.name, JSON.parse)
	// The walker returns MemberExpr when cursor is past the object — check resolvedSym on CallExpr parent too
	if (node.kind === NodeKind.MemberExpr) {
		if (node.resolvedSym !== null) return sgSuggestFromSym(node.resolvedSym);
		const md = node.data as MemberExprData;
		// Try looking up the property as a type member
		const objType = md.object.nodeType;
		if (objType !== null) {
			const prop = getProperty(objType, md.property);
			if (prop !== null) {
				return {
					name: md.property, kind: SymbolKind.Property, symType: prop,
					location: node.location, prefixScore: 0, scopeDepth: 0, contextFit: false,
					isExported: false, isMutable: false,
				};
			}
		}
		// Static member: try looking up the object as a class/enum
		const objSym = lookupSymbol(ctx.table, md.property);
		if (objSym !== null) return sgSuggestFromSym(objSym);
	}

	// CallExpr: cursor on the call — delegate to callee
	if (node.kind === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		if (cd.callee.resolvedSym !== null) return sgSuggestFromSym(cd.callee.resolvedSym);
		if (cd.callee.kind === NodeKind.Identifier) {
			const id = cd.callee.data as IdentifierData;
			const sym = lookupSymbol(ctx.table, id.name);
			if (sym !== null) return sgSuggestFromSym(sym);
		}
	}

	return null as unknown as SgSuggest;
}

// ===== sgFormatHover — markdown hover info =====

function sgSymbolKindName(kind: SymbolKind): string {
	return match (kind) {
		SymbolKind.Variable => "variable",
		SymbolKind.Function => "function",
		SymbolKind.Class => "class",
		SymbolKind.Interface => "interface",
		SymbolKind.TypeAlias => "type",
		SymbolKind.Enum => "enum",
		SymbolKind.Parameter => "parameter",
		SymbolKind.Property => "property",
		SymbolKind.Method => "method",
	};
}

// Format parameter list: (a: number, b: string)
function sgFormatParamList(t: Type): string {
	let result = "(";
	for (let i = 0; i < t.typeChildren.length; i = i + 1) {
		if (i > 0) result = result + ", ";
		if (i < t.typeNames.length && t.typeNames[i].length > 0) {
			result = result + t.typeNames[i] + ": ";
		}
		result = result + sgTypeToString(t.typeChildren[i]);
	}
	result = result + ")";
	return result;
}

// Format function type as declaration: function name(params): returnType
function sgFormatFuncDecl(name: string, t: Type): string {
	return "function " + name + sgFormatParamList(t) + ": " + sgTypeToString(t.typeReturn);
}

// Format interface fields as "field1: T1; field2: T2; ..." (up to 5)
function sgFormatFieldList(t: Type): string {
	if (t === null || t.typeNames.length === 0) return "";
	let result = "";
	const limit = 5;
	let maxLen = t.typeNames.length;
	if (maxLen > limit) maxLen = limit;
	for (let i = 0; i < maxLen; i = i + 1) {
		if (i > 0) result = result + "; ";
		result = result + t.typeNames[i];
		if (i < t.typeChildren.length) {
			result = result + ": " + sgTypeToString(t.typeChildren[i]);
		}
	}
	if (t.typeNames.length > limit) result = result + "; ...";
	return result;
}

export function sgFormatHover(suggest: SgSuggest): string {
	if (suggest === null) return "";
	const typeStr = sgTypeToString(suggest.symType);
	// Variable/Parameter: const x: number / let x: number / parameter x: string
	if (suggest.kind === SymbolKind.Variable || suggest.kind === SymbolKind.Parameter) {
		let kw = "";
		if (suggest.kind === SymbolKind.Parameter) {
			kw = "(parameter)";
		} else {
			if (suggest.isMutable) { kw = "let"; } else { kw = "const"; }
		}
		return "```ms\n" + kw + " " + suggest.name + ": " + typeStr + "\n```";
	}
	// Function: function name(params): returnType
	if (suggest.kind === SymbolKind.Function) {
		if (suggest.symType !== null && suggest.symType.kind === TypeKind.Function) {
			return "```ms\n" + sgFormatFuncDecl(suggest.name, suggest.symType) + "\n```";
		}
		return "```ms\nfunction " + suggest.name + "\n```";
	}
	// Method: (method) name(params): returnType
	if (suggest.kind === SymbolKind.Method) {
		if (suggest.symType !== null && suggest.symType.kind === TypeKind.Function) {
			return "```ms\n(method) " + suggest.name + sgFormatParamList(suggest.symType) + ": " + sgTypeToString(suggest.symType.typeReturn) + "\n```";
		}
		return "```ms\n(method) " + suggest.name + "\n```";
	}
	// Property: (property) name: type
	if (suggest.kind === SymbolKind.Property) {
		return "```ms\n(property) " + suggest.name + ": " + typeStr + "\n```";
	}
	// Interface: interface Name { field1: T1; field2: T2 }
	if (suggest.kind === SymbolKind.Interface) {
		if (suggest.symType !== null && suggest.symType.kind === TypeKind.Struct && suggest.symType.typeNames.length > 0) {
			const fields = sgFormatFieldList(suggest.symType);
			return "```ms\ninterface " + suggest.name + " { " + fields + " }\n```";
		}
		return "```ms\ninterface " + suggest.name + "\n```";
	}
	// Class: class Name
	if (suggest.kind === SymbolKind.Class) {
		return "```ms\nclass " + suggest.name + "\n```";
	}
	// Enum: enum Name { A, B, C }
	if (suggest.kind === SymbolKind.Enum) {
		if (suggest.symType !== null && suggest.symType.kind === TypeKind.Enum && suggest.symType.typeNames.length > 0) {
			const members = sgJoinFieldNames(suggest.symType.typeNames);
			return "```ms\nenum " + suggest.name + " { " + members + " }\n```";
		}
		return "```ms\nenum " + suggest.name + "\n```";
	}
	// TypeAlias: type T = underlying
	if (suggest.kind === SymbolKind.TypeAlias) {
		return "```ms\ntype " + suggest.name + " = " + typeStr + "\n```";
	}
	// Fallback
	const kindName = sgSymbolKindName(suggest.kind);
	return "```ms\n(" + kindName + ") " + suggest.name + ": " + typeStr + "\n```";
}

// Hover documentation section — annotations below the code block
export function sgFormatHoverDoc(suggest: SgSuggest, docComment: string): string {
	if (suggest === null) return "";
	let badges = "";
	if (suggest.isExported) badges = "**exported**";
	if (suggest.isMutable && suggest.kind === SymbolKind.Variable) {
		if (badges.length > 0) badges = badges + " | ";
		badges = badges + "**mutable**";
	}
	let doc = "";
	if (badges.length > 0) doc = badges;
	if (docComment.length > 0) {
		if (doc.length > 0) doc = doc + "\n\n---\n\n";
		doc = doc + docComment;
	}
	return doc;
}

// ===== Doc Comment Extraction =====

// Extract the line content at a given 1-indexed line number.
// Returns "" if line is out of range.
function sgExtractLine(source: string, line: number): string {
	if (line < 1) return "";
	const start = sgGetLineOffset(source, line);
	if (start >= source.length) return "";
	let end = start;
	while (end < source.length && charAt(source, end) !== "\n") {
		end = end + 1;
	}
	return sliceStr(source, start, end);
}

// Strip leading whitespace from a string.
function sgTrimLeft(s: string): string {
	let i = 0;
	while (i < s.length) {
		const ch = charAt(s, i);
		if (ch !== " " && ch !== "\t") break;
		i = i + 1;
	}
	if (i === 0) return s;
	return sliceStr(s, i, s.length);
}

// Extract doc comment above a declaration at the given line (1-indexed).
// Scans backwards through source for consecutive // or ## comment lines.
// Stops at blank lines or non-comment lines.
export function sgExtractDocComment(source: string, declLine: number): string {
	if (declLine <= 1) return "";
	// Collect comment lines backwards
	const lines: string[] = [];
	let curLine = declLine - 1;
	while (curLine >= 1) {
		const raw = sgExtractLine(source, curLine);
		const trimmed = sgTrimLeft(raw);
		// Check for // comment
		if (trimmed.length >= 2 && sliceStr(trimmed, 0, 2) === "//") {
			// Extract comment content after "// " or "//"
			let content = sliceStr(trimmed, 2, trimmed.length);
			if (content.length > 0 && charAt(content, 0) === " ") {
				content = sliceStr(content, 1, content.length);
			}
			lines.push(content);
			curLine = curLine - 1;
			continue;
		}
		// Check for ## comment (Standard reference style docstring)
		if (trimmed.length >= 2 && sliceStr(trimmed, 0, 2) === "##") {
			let content = sliceStr(trimmed, 2, trimmed.length);
			if (content.length > 0 && charAt(content, 0) === " ") {
				content = sliceStr(content, 1, content.length);
			}
			lines.push(content);
			curLine = curLine - 1;
			continue;
		}
		// Not a comment line — stop
		break;
	}
	if (lines.length === 0) return "";
	// Reverse and join (we collected bottom-up)
	let result = "";
	let i = lines.length - 1;
	while (i >= 0) {
		if (result.length > 0) result = result + "\n";
		result = result + lines[i];
		i = i - 1;
	}
	return result;
}

// ===== Cross-Module Helpers =====

// Find which import provides `name`. Returns the import source specifier or "".
// Walks ProgramData.programStmts, checks ImportDecl.importNames for a match.
// Also checks inside ExportDecl wrappers (re-exports).
export function sgFindImportSource(program: Node, name: string): string {
	if (program === null) return "";
	if (program.kind !== NodeKind.Program) return "";
	const data = program.data as ProgramData;
	for (let i = 0; i < data.programStmts.length; i = i + 1) {
		let stmt = data.programStmts[i];
		// Unwrap ExportDecl (re-exports)
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			stmt = ed.exportedDecl;
		}
		if (stmt.kind === NodeKind.ImportDecl) {
			const imp = stmt.data as ImportDeclData;
			for (let j = 0; j < imp.importNames.length; j = j + 1) {
				if (imp.importNames[j] === name) {
					return imp.importSource;
				}
			}
		}
	}
	return "";
}

// Helper: get declaration name from a top-level node.
function sgGetDeclName(node: Node): string {
	if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		return d.fnName;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		return d.declName;
	}
	if (node.kind === NodeKind.InterfaceDecl) {
		const d = node.data as InterfaceDeclData;
		return d.interfaceName;
	}
	if (node.kind === NodeKind.EnumDecl) {
		const d = node.data as EnumDeclData;
		return d.enumName;
	}
	if (node.kind === NodeKind.TypeAliasDecl) {
		const d = node.data as TypeAliasDeclData;
		return d.aliasName;
	}
	if (node.kind === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		return d.className;
	}
	return "";
}

// Find the declaration location of `name` in a program AST.
// Walks top-level stmts (including inside ExportDecl) for matching declarations.
// Returns { line: 0, column: 0 } if not found.
export function sgFindExportedDecl(program: Node, name: string): SourceLocation {
	const notFound: SourceLocation = { line: 0, column: 0 };
	if (program === null) return notFound;
	if (program.kind !== NodeKind.Program) return notFound;
	const data = program.data as ProgramData;
	for (let i = 0; i < data.programStmts.length; i = i + 1) {
		let stmt = data.programStmts[i];
		let inner = stmt;
		// Unwrap ExportDecl
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			inner = ed.exportedDecl;
		}
		const declName = sgGetDeclName(inner);
		if (declName === name) {
			return inner.location;
		}
	}
	return notFound;
}

// Document symbol detail — type signature for outline view
export function sgSymbolDetail(suggest: SgSuggest): string {
	if (suggest === null) return "";
	return sgTypeToString(suggest.symType);
}

// ===== sgCollectDiagnostics — wrap checker errors =====

export function sgCollectDiagnostics(ctx: CheckerContext): SgDiagnostic[] {
	const result: SgDiagnostic[] = [];
	for (let i = 0; i < ctx.errors.length; i = i + 1) {
		const err = ctx.errors[i];
		// Map Severity enum to LSP DiagnosticSeverity (1=Error, 2=Warning, 3=Info, 4=Hint)
		const lspSeverity = (err.severity as number) + 1;
		const diag: SgDiagnostic = {
			message: err.message,
			line: err.line > 0 ? err.line : 1,
			column: err.column,
			severity: lspSeverity,
		};
		result.push(diag);
	}
	return result;
}

// ===== Completion Helpers =====

function sgIsIdentChar(ch: string): boolean {
	if (ch === "_") return true;
	const identChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
	for (let i = 0; i < identChars.length; i = i + 1) {
		if (charAt(identChars, i) === ch) return true;
	}
	return false;
}

function sgGetLineOffset(source: string, line: number): number {
	// line is 1-indexed. Returns offset of the first char on that line.
	let offset = 0;
	let currentLine = 1;
	while (offset < source.length && currentLine < line) {
		if (charAt(source, offset) === "\n") {
			currentLine = currentLine + 1;
		}
		offset = offset + 1;
	}
	return offset;
}

function sgStartsWith(s: string, prefix: string): boolean {
	if (prefix.length === 0) return true;
	if (prefix.length > s.length) return false;
	return sliceStr(s, 0, prefix.length) === prefix;
}

function sgIsTypeKind(kind: SymbolKind): boolean {
	return kind === SymbolKind.Interface || kind === SymbolKind.Class
		|| kind === SymbolKind.Enum || kind === SymbolKind.TypeAlias;
}

// ===== Completion Ranking =====

function sgToLower(ch: string): string {
	return match (ch) {
		"A" => "a", "B" => "b", "C" => "c", "D" => "d", "E" => "e",
		"F" => "f", "G" => "g", "H" => "h", "I" => "i", "J" => "j",
		"K" => "k", "L" => "l", "M" => "m", "N" => "n", "O" => "o",
		"P" => "p", "Q" => "q", "R" => "r", "S" => "s", "T" => "t",
		"U" => "u", "V" => "v", "W" => "w", "X" => "x", "Y" => "y",
		"Z" => "z",
		_ => ch,
	};
}

function sgCaseEqual(a: string, b: string): boolean {
	return sgToLower(a) === sgToLower(b);
}

// Returns 0=None, 1=Substr, 2=Prefix
function sgPrefixMatch(prefix: string, name: string): number {
	if (prefix.length === 0) return 2;
	if (prefix.length > name.length) return 0;
	// Check prefix match (case-insensitive)
	let isPrefix = true;
	for (let k = 0; k < prefix.length; k = k + 1) {
		if (!sgCaseEqual(charAt(prefix, k), charAt(name, k))) {
			isPrefix = false;
			break;
		}
	}
	if (isPrefix) return 2;
	// Check substring match (case-insensitive)
	for (let start = 1; start + prefix.length <= name.length; start = start + 1) {
		let matched = true;
		for (let m = 0; m < prefix.length; m = m + 1) {
			if (!sgCaseEqual(charAt(prefix, m), charAt(name, start + m))) {
				matched = false;
				break;
			}
		}
		if (matched) return 1;
	}
	return 0;
}

function sgCompareSuggestions(a: SgSuggest, b: SgSuggest): number {
	// Higher prefixScore first
	if (a.prefixScore !== b.prefixScore) return b.prefixScore - a.prefixScore;
	// contextFit true first
	const aFit = a.contextFit ? 1 : 0;
	const bFit = b.contextFit ? 1 : 0;
	if (aFit !== bFit) return bFit - aFit;
	// Lower scopeDepth first (closer scope)
	if (a.scopeDepth !== b.scopeDepth) return a.scopeDepth - b.scopeDepth;
	// Shorter name tiebreaker (more concise = likely more relevant)
	if (a.name.length !== b.name.length) return a.name.length - b.name.length;
	return 0;
}

function sgSortSuggestions(list: SgSuggest[]): void {
	for (let i = 1; i < list.length; i = i + 1) {
		const current = list[i];
		let j = i - 1;
		while (j >= 0 && sgCompareSuggestions(list[j], current) > 0) {
			list[j + 1] = list[j];
			j = j - 1;
		}
		list[j + 1] = current;
	}
}

// ===== sgDetectCompletionContext — scan backwards from cursor =====

export function sgDetectCompletionContext(source: string, line: number, col: number): SgCompletionKind {
	const lineOffset = sgGetLineOffset(source, line);
	const cursorOffset = lineOffset + col;
	// Scan backwards past any identifier chars (the prefix being typed)
	let pos = cursorOffset - 1;
	while (pos >= 0 && sgIsIdentChar(charAt(source, pos))) {
		pos = pos - 1;
	}
	// Skip whitespace
	while (pos >= 0 && charAt(source, pos) === " ") {
		pos = pos - 1;
	}
	// Check the character just before the identifier
	if (pos >= 0) {
		const ch = charAt(source, pos);
		if (ch === ".") return SgCompletionKind.MemberAccess;
		if (ch === ":") return SgCompletionKind.TypeAnnotation;
	}
	return SgCompletionKind.Identifier;
}

// ===== sgGetPrefix — extract word fragment at cursor =====

export function sgGetPrefix(source: string, line: number, col: number): string {
	const lineOffset = sgGetLineOffset(source, line);
	const cursorOffset = lineOffset + col;
	let start = cursorOffset;
	while (start > 0 && sgIsIdentChar(charAt(source, start - 1))) {
		start = start - 1;
	}
	if (start >= cursorOffset) return "";
	return sliceStr(source, start, cursorOffset);
}

// ===== sgGetCompletionCandidates — collect matching symbols =====

function sgCompleteMemberAccess(ctx: CheckerContext, prefix: string, receiverType: Type): SgSuggest[] {
	const result: SgSuggest[] = [];
	// Dot completion: properties from receiver type
	if (receiverType !== null && receiverType.kind === TypeKind.Struct) {
		for (let i = 0; i < receiverType.typeNames.length; i = i + 1) {
			const propName = receiverType.typeNames[i];
			const ps = sgPrefixMatch(prefix, propName);
			if (ps > 0) {
				const propType = i < receiverType.typeChildren.length
					? receiverType.typeChildren[i] : unknownType();
				const loc: SourceLocation = { line: 0, column: 0 };
				const item: SgSuggest = {
					name: propName, kind: SymbolKind.Property, symType: propType,
					location: loc, prefixScore: ps, scopeDepth: 0, contextFit: false,
					isExported: false, isMutable: false,
				};
				result.push(item);
			}
		}
	}
	// Enum member completion
	if (receiverType !== null && receiverType.kind === TypeKind.Enum) {
		for (let i = 0; i < receiverType.typeNames.length; i = i + 1) {
			const memberName = receiverType.typeNames[i];
			const ps = sgPrefixMatch(prefix, memberName);
			if (ps > 0) {
				const loc: SourceLocation = { line: 0, column: 0 };
				const item: SgSuggest = {
					name: memberName, kind: SymbolKind.Property, symType: receiverType,
					location: loc, prefixScore: ps, scopeDepth: 0, contextFit: false,
					isExported: false, isMutable: false,
				};
				result.push(item);
			}
		}
	}
	// Extension methods — type-based matching (shared with checker)
	if (receiverType !== null && ctx.extensionRegistry !== null) {
		// Collect unique method names first, then filter by receiver type
		const seenMethods: string[] = [];
		for (let j = 0; j < ctx.extensionRegistry.methods.length; j = j + 1) {
			const ext = ctx.extensionRegistry.methods[j];
			const ps = sgPrefixMatch(prefix, ext.methodName);
			if (ps === 0) continue;
			// Deduplicate: skip if we already added this method name
			let seen = false;
			for (let si = 0; si < seenMethods.length; si = si + 1) {
				if (seenMethods[si] === ext.methodName) { seen = true; }
			}
			if (seen) continue;
			// Type-based receiver matching (same algo as checker)
			const allByName = findAllExtensionsByName(ctx.extensionRegistry, ext.methodName);
			const matched = filterExtsByReceiverType(allByName, receiverType);
			if (matched.length > 0) {
				seenMethods.push(ext.methodName);
				// Use first match's type; strip receiver param for instance extensions
				const bestExt = matched[0];
				let sigType = getExtFnType(bestExt);
				if (!bestExt.isStatic && sigType.typeChildren !== null && sigType.typeChildren.length > 0) {
					sigType = stripReceiverParam(sigType);
				}
				const loc: SourceLocation = { line: 0, column: 0 };
				const item: SgSuggest = {
					name: bestExt.methodName, kind: SymbolKind.Method, symType: sigType,
					location: loc, prefixScore: ps, scopeDepth: 0, contextFit: false,
					isExported: false, isMutable: false,
				};
				result.push(item);
			}
		}
	}
	sgSortSuggestions(result);
	return result;
}

export function sgGetCompletionCandidates(ctx: CheckerContext, kind: SgCompletionKind, prefix: string, receiverType: Type): SgSuggest[] {
	if (kind === SgCompletionKind.MemberAccess) {
		return sgCompleteMemberAccess(ctx, prefix, receiverType);
	}

	// Walk scope chain for Identifier or TypeAnnotation
	const result: SgSuggest[] = [];
	let scope = ctx.table.current;
	let depth = 0;
	while (scope !== null) {
		for (let i = 0; i < scope.symbols.length; i = i + 1) {
			const sym = scope.symbols[i];
			const ps = sgPrefixMatch(prefix, sym.name);
			if (ps > 0) {
				const inTypeCtx = kind === SgCompletionKind.TypeAnnotation;
				const cf = inTypeCtx === sgIsTypeKind(sym.symbolKind);
				if (!inTypeCtx || sgIsTypeKind(sym.symbolKind)) {
					const item: SgSuggest = {
						name: sym.name, kind: sym.symbolKind, symType: sym.symbolType,
						location: sym.location, prefixScore: ps, scopeDepth: depth, contextFit: cf,
						isExported: hasFlag(sym, SymbolFlag.Exported), isMutable: hasFlag(sym, SymbolFlag.Mutable),
					};
					result.push(item);
				}
			}
		}
		scope = scope.parent;
		depth = depth + 1;
	}

	sgSortSuggestions(result);
	return result;
}

// ===== Document Symbols — collect top-level declarations =====

// Join field/member names as "a, b, c" — truncated to 3 items
function sgJoinFieldNames(names: string[]): string {
	if (names.length === 0) return "";
	let result = "";
	const limit = 3;
	const maxLen = names.length < limit ? names.length : limit;
	for (let i = 0; i < maxLen; i = i + 1) {
		if (i > 0) result = result + ", ";
		result = result + names[i];
	}
	if (names.length > limit) result = result + ", ...";
	return result;
}

function sgGetSymbolDetail(ctx: CheckerContext, name: string): string {
	const sym = lookupSymbol(ctx.table, name);
	if (sym === null) return "";
	if (sym.symbolType === null) return "";
	return sgTypeToString(sym.symbolType);
}

function sgCollectOneSymbol(node: Node, ctx: CheckerContext, result: SgDocumentSymbol[]): void {
	if (node === null) return;

	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		const dt = sgGetSymbolDetail(ctx, fd.fnName);
		const item: SgDocumentSymbol = { name: fd.fnName, kind: SymbolKind.Function, location: node.location, detail: dt, isMutable: false };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		const dt = sgGetSymbolDetail(ctx, vd.declName);
		const mut = vd.declKind !== DeclKind.Const;
		const item: SgDocumentSymbol = { name: vd.declName, kind: SymbolKind.Variable, location: node.location, detail: dt, isMutable: mut };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.InterfaceDecl) {
		const ifd = node.data as InterfaceDeclData;
		const dt = sgJoinFieldNames(ifd.interfaceFields);
		const item: SgDocumentSymbol = { name: ifd.interfaceName, kind: SymbolKind.Interface, location: node.location, detail: dt, isMutable: false };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.EnumDecl) {
		const ed = node.data as EnumDeclData;
		const dt = sgJoinFieldNames(ed.enumMembers);
		const item: SgDocumentSymbol = { name: ed.enumName, kind: SymbolKind.Enum, location: node.location, detail: dt, isMutable: false };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.ClassDecl) {
		const cd = node.data as ClassDeclData;
		const item: SgDocumentSymbol = { name: cd.className, kind: SymbolKind.Class, location: node.location, detail: cd.classExtends, isMutable: false };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.TypeAliasDecl) {
		const td = node.data as TypeAliasDeclData;
		const dt = sgGetSymbolDetail(ctx, td.aliasName);
		const item: SgDocumentSymbol = { name: td.aliasName, kind: SymbolKind.TypeAlias, location: node.location, detail: dt, isMutable: false };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.ExportDecl) {
		const xd = node.data as ExportDeclData;
		sgCollectOneSymbol(xd.exportedDecl, ctx, result);
		return;
	}
}

export function sgCollectSymbolsInFile(ctx: CheckerContext, program: Node): SgDocumentSymbol[] {
	const result: SgDocumentSymbol[] = [];
	if (program === null || program.kind !== NodeKind.Program) return result;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i = i + 1) {
		sgCollectOneSymbol(pd.programStmts[i], ctx, result);
	}
	return result;
}

// ===== Signature Help — format function signatures =====

function sgBuildSignatureInfo(name: string, fnType: Type): SgSignatureInfo {
	const paramLabels: string[] = [];
	let label = name + "(";
	for (let i = 0; i < fnType.typeChildren.length; i = i + 1) {
		if (i > 0) label = label + ", ";
		let paramLabel = "";
		if (i < fnType.typeNames.length && fnType.typeNames[i].length > 0) {
			paramLabel = fnType.typeNames[i] + ": " + sgTypeToString(fnType.typeChildren[i]);
		} else {
			paramLabel = sgTypeToString(fnType.typeChildren[i]);
		}
		paramLabels.push(paramLabel);
		label = label + paramLabel;
	}
	label = label + "): " + sgTypeToString(fnType.typeReturn);
	const info: SgSignatureInfo = { label, paramLabels };
	return info;
}

export function sgFormatSignature(sym: Symbol): SgSignatureInfo[] {
	const result: SgSignatureInfo[] = [];
	if (sym === null) return result;
	if (sym.symbolType === null || sym.symbolType.kind !== TypeKind.Function) return result;

	// Main signature
	const main = sgBuildSignatureInfo(sym.name, sym.symbolType);
	result.push(main);

	// Overloads
	for (let i = 0; i < sym.overloads.length; i = i + 1) {
		const ovl = sym.overloads[i];
		if (ovl.symbolType !== null && ovl.symbolType.kind === TypeKind.Function) {
			const ovlInfo = sgBuildSignatureInfo(sym.name, ovl.symbolType);
			result.push(ovlInfo);
		}
	}

	return result;
}

// ===== sgFormatExtensionSignatures — build signatures filtered by receiver type =====

export function sgFormatExtensionSignatures(ctx: CheckerContext, methodName: string, receiverType: Type): SgSignatureInfo[] {
	if (ctx.extensionRegistry === null || receiverType === null) return [];
	const allByName = findAllExtensionsByName(ctx.extensionRegistry, methodName);
	const matched = filterExtsByReceiverType(allByName, receiverType);
	const result: SgSignatureInfo[] = [];
	for (let i = 0; i < matched.length; i = i + 1) {
		const ext = matched[i];
		let fnType = getExtFnType(ext);
		if (fnType === null || fnType.kind !== TypeKind.Function) continue;
		if (!ext.isStatic && fnType.typeChildren.length > 0) {
			fnType = stripReceiverParam(fnType);
		}
		result.push(sgBuildSignatureInfo(methodName, fnType));
	}
	return result;
}

// ===== sgGetCalleeAtCursor — find function name for signature help =====

// Scans backwards from cursor to matching unclosed '(', then extracts
// the identifier before it (the callee name).
// Returns "" if no enclosing call found.
export function sgGetCalleeAtCursor(source: string, line: number, col: number): string {
	const lineOffset = sgGetLineOffset(source, line);
	const cursorOffset = lineOffset + col;
	let pos = cursorOffset - 1;
	let depth = 0;

	// Find the matching unclosed '('
	while (pos >= 0) {
		const ch = charAt(source, pos);
		if (ch === ")") { depth = depth + 1; }
		if (ch === "(") {
			if (depth === 0) {
				// Found the open paren. Now extract the identifier before it.
				let end = pos;
				pos = pos - 1;
				// Skip whitespace
				while (pos >= 0) {
					const ws = charAt(source, pos);
					if (ws !== " " && ws !== "\t") {
						let identEnd = pos + 1;
						// Scan backwards through identifier chars
						while (pos >= 0) {
							const ic = charAt(source, pos);
							if (sgIsIdentChar(ic)) {
								pos = pos - 1;
							} else {
								return sliceStr(source, pos + 1, identEnd);
							}
						}
						return sliceStr(source, 0, identEnd);
					}
					pos = pos - 1;
				}
				return "";
			}
			depth = depth - 1;
		}
		pos = pos - 1;
	}
	return "";
}

// ===== sgGetReceiverAtCursor — extract receiver for dot calls =====
// For "console.log(x", returns "console". For "foo(x", returns "".
// Scans backwards from the callee identifier to find "." + identifier pattern.

export function sgGetReceiverAtCursor(source: string, line: number, col: number): string {
	const lineOffset = sgGetLineOffset(source, line);
	const cursorOffset = lineOffset + col;
	let pos = cursorOffset - 1;
	let depth = 0;
	// Find matching unclosed '('
	while (pos >= 0) {
		const ch = charAt(source, pos);
		if (ch === ")") { depth = depth + 1; }
		if (ch === "(") {
			if (depth === 0) {
				// Skip backwards past callee identifier
				pos = pos - 1;
				while (pos >= 0 && (charAt(source, pos) === " " || charAt(source, pos) === "\t")) {
					pos = pos - 1;
				}
				while (pos >= 0 && sgIsIdentChar(charAt(source, pos))) {
					pos = pos - 1;
				}
				// Check for dot
				if (pos >= 0 && charAt(source, pos) === ".") {
					pos = pos - 1;
					// Extract receiver identifier
					const recEnd = pos + 1;
					while (pos >= 0 && sgIsIdentChar(charAt(source, pos))) {
						pos = pos - 1;
					}
					return sliceStr(source, pos + 1, recEnd);
				}
				return "";
			}
			depth = depth - 1;
		}
		pos = pos - 1;
	}
	return "";
}

// ===== Active Parameter — count commas from nearest unclosed ( =====

export function sgCountActiveParam(source: string, line: number, col: number): number {
	const lineOffset = sgGetLineOffset(source, line);
	const cursorOffset = lineOffset + col;
	let pos = cursorOffset - 1;
	let depth = 0;
	let commas = 0;
	while (pos >= 0) {
		const ch = charAt(source, pos);
		if (ch === ")") { depth = depth + 1; }
		if (ch === "(") {
			if (depth === 0) return commas;
			depth = depth - 1;
		}
		if (ch === "," && depth === 0) { commas = commas + 1; }
		pos = pos - 1;
	}
	return commas;
}

// ===== Inlay Hints — type annotations + parameter names =====

export enum SgInlayHintKind {
	Type,       // 1 in LSP
	Parameter,  // 2 in LSP
	Exception,  // mapped to 1 (Type) in LSP — shows "throws ErrorType"
}

export interface SgInlayHint {
	label: string;
	line: number;
	col: number;
	hintKind: SgInlayHintKind;
}

// Walk top-level statements in range [startLine, endLine] (1-indexed, inclusive).
// Collect type hints for variables without annotations,
// and parameter name hints at call sites.
export function sgCollectInlayHints(
	ctx: CheckerContext, program: Node, startLine: number, endLine: number
): SgInlayHint[] {
	const result: SgInlayHint[] = [];
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i = i + 1) {
		const stmt = pd.programStmts[i];
		sgCollectHintsInNode(ctx, stmt, startLine, endLine, result);
	}
	return result;
}

function sgCollectHintsInNode(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHint[]
): void {
	if (node === null) return;
	const loc = node.location;
	// Skip nodes outside range
	if (loc.line > endLine) return;

	// Variable declarations: type hint if no annotation + walk initializer
	if (node.kind === NodeKind.VariableDecl) {
		sgCollectVarTypeHint(ctx, node, startLine, endLine, hints);
		const vd = node.data as VariableDeclData;
		if (vd.initializer !== null) {
			sgCollectHintsInNode(ctx, vd.initializer, startLine, endLine, hints);
		}
		return;
	}

	// Function declarations: exception hint + walk body for call sites + nested vars
	if (node.kind === NodeKind.FunctionDecl) {
		sgCollectExceptionHints(ctx, node, startLine, endLine, hints);
		const fd = node.data as FunctionDeclData;
		if (fd.fnBody !== null) {
			sgCollectHintsInNode(ctx, fd.fnBody, startLine, endLine, hints);
		}
		return;
	}

	// Try expressions: exception hint showing error type
	if (node.kind === NodeKind.TryExpr) {
		sgCollectExceptionHints(ctx, node, startLine, endLine, hints);
		return;
	}

	// Call expressions: parameter name hints
	if (node.kind === NodeKind.CallExpr) {
		sgCollectCallParamHints(ctx, node, startLine, endLine, hints);
		return;
	}

	// Generic fallback: recurse into all children
	forEachChild(node, (child: Node): void => {
		sgCollectHintsInNode(ctx, child, startLine, endLine, hints);
	});
}

function sgCollectVarTypeHint(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHint[]
): void {
	const vd = node.data as VariableDeclData;
	if (node.location.line < startLine) return;
	if (node.location.line > endLine) return;

	// Only show hint if no explicit type annotation
	if (vd.declType.length > 0) return;

	const sym = lookupSymbol(ctx.table, vd.declName);
	if (sym === null) return;
	if (sym.symbolType === null) return;
	if (sym.symbolType.kind === TypeKind.Unknown) return;
	if (sym.symbolType.kind === TypeKind.Error) return;

	const typeStr = sgTypeToString(sym.symbolType);
	const hint: SgInlayHint = {
		label: ": " + typeStr,
		line: node.location.line,
		col: node.location.column + vd.declName.length,
		hintKind: SgInlayHintKind.Type,
	};
	hints.push(hint);
}

function sgCollectCallParamHints(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHint[]
): void {
	const cd = node.data as CallExprData;
	if (node.location.line < startLine) return;
	if (node.location.line > endLine) return;

	// Resolve callee name
	let calleeName = "";
	if (cd.callee !== null && cd.callee.kind === NodeKind.Identifier) {
		const cid = cd.callee.data as IdentifierData;
		calleeName = cid.name;
	}
	if (calleeName === "") return;

	const sym = lookupSymbol(ctx.table, calleeName);
	if (sym === null) return;
	if (sym.symbolType === null) return;
	if (sym.symbolType.kind !== TypeKind.Function) return;

	// Get parameter names from the function type
	const paramNames = sym.symbolType.typeNames;
	if (paramNames.length === 0) return;

	const paramLimit = cd.arguments.length < paramNames.length ? cd.arguments.length : paramNames.length;
	for (let j = 0; j < paramLimit; j = j + 1) {
		const arg = cd.arguments[j];
		if (arg === null) { continue; }
		// Skip hints for trivially obvious args (same name as param)
		let argName = "";
		if (arg.kind === NodeKind.Identifier) {
			const aid = arg.data as IdentifierData;
			argName = aid.name;
		}
		if (argName !== paramNames[j]) {
			const hint: SgInlayHint = {
				label: paramNames[j] + ":",
				line: arg.location.line,
				col: arg.location.column,
				hintKind: SgInlayHintKind.Parameter,
			};
			hints.push(hint);
		}
	}

	// Also walk into argument expressions for nested calls
	for (let j = 0; j < cd.arguments.length; j = j + 1) {
		sgCollectHintsInNode(ctx, cd.arguments[j], startLine, endLine, hints);
	}
}

// ===== Exception Inlay Hints =====

// Infer the return type of a call expression's callee.
function inferCalleeReturnType(ctx: CheckerContext, node: Node): Type {
	if (node.kind === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		if (cd.callee !== null && cd.callee.kind === NodeKind.Identifier) {
			const id = cd.callee.data as IdentifierData;
			const sym = lookupSymbol(ctx.table, id.name);
			if (sym !== null && sym.symbolType !== null && sym.symbolType.kind === TypeKind.Function) {
				return sym.symbolType.typeReturn;
			}
		}
	}
	if (node.kind === NodeKind.Identifier) {
		const id = node.data as IdentifierData;
		const sym = lookupSymbol(ctx.table, id.name);
		if (sym !== null && sym.symbolType !== null && sym.symbolType.kind === TypeKind.Function) {
			return sym.symbolType.typeReturn;
		}
	}
	return null;
}

// Collect exception hints for try expressions and functions returning Result<T,E>.
function sgCollectExceptionHints(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHint[]
): void {
	// TryExpr: show the error type being caught
	if (node.kind === NodeKind.TryExpr) {
		if (node.location.line < startLine || node.location.line > endLine) return;
		const d = node.data as TryExprData;
		const argType = inferCalleeReturnType(ctx, d.tryArg);
		if (argType !== null && argType.kind === TypeKind.Result && argType.typeExtra !== null) {
			const errTypeName = typeNameOf(argType.typeExtra);
			if (errTypeName !== "" && errTypeName !== "unknown") {
				const hint: SgInlayHint = {
					label: "throws " + errTypeName,
					line: node.location.line,
					col: node.location.column + 3,
					hintKind: SgInlayHintKind.Exception,
				};
				hints.push(hint);
			}
		}
		return;
	}

	// FunctionDecl returning Result<T,E>: show "throws E" after function name
	if (node.kind === NodeKind.FunctionDecl) {
		if (node.location.line < startLine || node.location.line > endLine) return;
		const fd = node.data as FunctionDeclData;
		const retType = node.nodeType;
		if (retType !== null && retType.kind === TypeKind.Function && retType.typeReturn !== null) {
			if (retType.typeReturn.kind === TypeKind.Result && retType.typeReturn.typeExtra !== null) {
				const errName = typeNameOf(retType.typeReturn.typeExtra);
				if (errName !== "" && errName !== "unknown") {
					const hint: SgInlayHint = {
						label: "throws " + errName,
						line: node.location.line,
						col: node.location.column + fd.fnName.length,
						hintKind: SgInlayHintKind.Exception,
					};
					hints.push(hint);
				}
			}
		}
	}
}

// ===== Semantic Tokens — server-side highlighting =====

// LSP Semantic Token Types (index = type ID, must match legend in handleInitialize):
// 0=namespace, 1=type, 2=class, 3=enum, 4=interface, 5=struct,
// 6=typeParameter, 7=parameter, 8=variable, 9=property,
// 10=enumMember, 11=event, 12=function, 13=method, 14=macro,
// 15=keyword, 16=modifier, 17=comment, 18=string, 19=number,
// 20=regexp, 21=operator, 22=decorator
//
// Modifiers (bit positions): 0=declaration, 1=definition, 2=readonly, 3=static

export interface SgSemanticToken {
	line: number;       // 1-indexed (converted to 0-indexed by handler)
	col: number;        // 1-indexed (converted to 0-indexed by handler)
	length: number;
	tokenType: number;  // index into legend
	modifiers: number;  // bitmask
}

export function sgCollectSemanticTokens(ctx: CheckerContext, program: Node): SgSemanticToken[] {
	const result: SgSemanticToken[] = [];
	if (program === null) return result;
	sgCollectTokensInNode(ctx, program, result);
	return result;
}

// Map SymbolKind to semantic token type index
function sgSymbolToTokenType(kind: SymbolKind): number {
	if (kind === SymbolKind.Function) return 12;
	if (kind === SymbolKind.Method) return 13;
	if (kind === SymbolKind.Variable) return 8;
	if (kind === SymbolKind.Parameter) return 7;
	if (kind === SymbolKind.Class) return 2;
	if (kind === SymbolKind.Interface) return 4;
	if (kind === SymbolKind.Enum) return 3;
	if (kind === SymbolKind.TypeAlias) return 1;
	if (kind === SymbolKind.Property) return 9;
	return 8; // default: variable
}

function sgCollectTokensInNode(ctx: CheckerContext, node: Node, tokens: SgSemanticToken[]): void {
	if (node === null) return;
	const loc = node.location;

	// Identifiers: look up symbol for semantic classification
	if (node.kind === NodeKind.Identifier) {
		const id = node.data as IdentifierData;
		if (id.name.length === 0) return;
		const sym = lookupSymbol(ctx.table, id.name);
		if (sym !== null) {
			const tt = sgSymbolToTokenType(sym.symbolKind);
			let mods: int32 = 0;
			if (!hasFlag(sym, SymbolFlag.Mutable) && sym.symbolKind === SymbolKind.Variable) mods = 4; // readonly bit 2
			if (sym.builtinKind.length > 0) mods = mods | 16; // defaultLibrary bit 4
			const tok: SgSemanticToken = { line: loc.line, col: loc.column, length: id.name.length, tokenType: tt, modifiers: mods };
			tokens.push(tok);
		}
		return;
	}

	// Declaration names get declaration modifier (bit 0)
	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		if (fd.fnName.length > 0) {
			// "function " = 9 chars offset to name
			const tok: SgSemanticToken = { line: loc.line, col: loc.column + 9, length: fd.fnName.length, tokenType: 12, modifiers: 1 };
			tokens.push(tok);
		}
		if (fd.fnBody !== null) sgCollectTokensInNode(ctx, fd.fnBody, tokens);
		return;
	}

	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		if (vd.declName.length > 0) {
			let mods = 1; // declaration
			// "const " = 6, "let " = 4, "var " = 4
			let kwLen = 4;
			if (vd.declKind === DeclKind.Const) {
				mods = 5; // declaration + readonly (1 + 4)
				kwLen = 6;
			}
			const tok: SgSemanticToken = { line: loc.line, col: loc.column + kwLen, length: vd.declName.length, tokenType: 8, modifiers: mods };
			tokens.push(tok);
		}
		if (vd.initializer !== null) sgCollectTokensInNode(ctx, vd.initializer, tokens);
		return;
	}

	if (node.kind === NodeKind.InterfaceDecl) {
		const ifd = node.data as InterfaceDeclData;
		if (ifd.interfaceName.length > 0) {
			// "interface " = 10 chars offset to name
			const tok: SgSemanticToken = { line: loc.line, col: loc.column + 10, length: ifd.interfaceName.length, tokenType: 4, modifiers: 1 };
			tokens.push(tok);
		}
		return;
	}

	if (node.kind === NodeKind.EnumDecl) {
		const ed = node.data as EnumDeclData;
		if (ed.enumName.length > 0) {
			// "enum " = 5 chars offset to name
			const tok: SgSemanticToken = { line: loc.line, col: loc.column + 5, length: ed.enumName.length, tokenType: 3, modifiers: 1 };
			tokens.push(tok);
		}
		return;
	}

	if (node.kind === NodeKind.ClassDecl) {
		const cd = node.data as ClassDeclData;
		if (cd.className.length > 0) {
			// "class " = 6 chars offset to name
			const tok: SgSemanticToken = { line: loc.line, col: loc.column + 6, length: cd.className.length, tokenType: 2, modifiers: 1 };
			tokens.push(tok);
		}
		for (let ci = 0; ci < cd.classBody.length; ci = ci + 1) {
			sgCollectTokensInNode(ctx, cd.classBody[ci], tokens);
		}
		return;
	}

	if (node.kind === NodeKind.TypeAliasDecl) {
		const td = node.data as TypeAliasDeclData;
		if (td.aliasName.length > 0) {
			// "type " = 5 chars offset to name
			const tok: SgSemanticToken = { line: loc.line, col: loc.column + 5, length: td.aliasName.length, tokenType: 1, modifiers: 1 };
			tokens.push(tok);
		}
		return;
	}

	// CallExpr: if callee is MemberExpr, emit method (not property) for the property name
	if (node.kind === NodeKind.CallExpr) {
		const ce = node.data as CallExprData;
		if (ce.callee !== null && ce.callee.kind === NodeKind.MemberExpr) {
			const me = ce.callee.data as MemberExprData;
			sgCollectTokensInNode(ctx, me.object, tokens);
			if (me.property.length > 0) {
				const ceLoc = ce.callee.location;
				const tok: SgSemanticToken = { line: ceLoc.line, col: ceLoc.column + 1, length: me.property.length, tokenType: 13, modifiers: 0 };
				tokens.push(tok);
			}
		} else {
			sgCollectTokensInNode(ctx, ce.callee, tokens);
		}
		// Recurse into arguments
		let ai = 0;
		while (ai < ce.arguments.length) {
			sgCollectTokensInNode(ctx, ce.arguments[ai], tokens);
			ai = ai + 1;
		}
		return;
	}

	// MemberExpr: recurse into object, emit token for property name
	if (node.kind === NodeKind.MemberExpr) {
		const me = node.data as MemberExprData;
		sgCollectTokensInNode(ctx, me.object, tokens);
		if (me.property.length > 0) {
			// loc is at the ".", property starts right after
			const tok: SgSemanticToken = { line: loc.line, col: loc.column + 1, length: me.property.length, tokenType: 9, modifiers: 0 };
			tokens.push(tok);
		}
		return;
	}

	// Compound nodes — recurse into children
	sgCollectTokensCompound(ctx, node, tokens);
}

function sgCollectTokensCompound(ctx: CheckerContext, node: Node, tokens: SgSemanticToken[]): void {
	forEachChild(node, (child: Node): void => {
		sgCollectTokensInNode(ctx, child, tokens);
	});
}

// Sort tokens by (line, col) for delta encoding — insertion sort
export function sgSortTokens(tokens: SgSemanticToken[]): void {
	let i = 1;
	while (i < tokens.length) {
		const t = tokens[i];
		let j = i - 1;
		while (j >= 0) {
			const tj = tokens[j];
			if (tj.line < t.line) break;
			if (tj.line === t.line && tj.col <= t.col) break;
			tokens[j + 1] = tokens[j];
			j = j - 1;
		}
		tokens[j + 1] = t;
		i = i + 1;
	}
}

// ===== Symbol Reference Index =====

export interface SgSymbolRef {
	name: string;
	line: number;
	col: number;
	nameLen: number;
	isDecl: boolean;
}

export function sgCollectReferences(program: Node): SgSymbolRef[] {
	const result: SgSymbolRef[] = [];
	if (program === null) return result;
	sgCollectRefsInNode(program, result);
	return result;
}

function sgCollectRefsInNode(node: Node, refs: SgSymbolRef[]): void {
	if (node === null) return;
	const loc = node.location;

	if (node.kind === NodeKind.Identifier) {
		const id = node.data as IdentifierData;
		const ref: SgSymbolRef = { name: id.name, line: loc.line, col: loc.column, nameLen: id.name.length, isDecl: false };
		refs.push(ref);
		return;
	}

	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		const ref: SgSymbolRef = { name: vd.declName, line: loc.line, col: loc.column, nameLen: vd.declName.length, isDecl: true };
		refs.push(ref);
		if (vd.initializer !== null) sgCollectRefsInNode(vd.initializer, refs);
		return;
	}

	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		const ref: SgSymbolRef = { name: fd.fnName, line: loc.line, col: loc.column, nameLen: fd.fnName.length, isDecl: true };
		refs.push(ref);
		if (fd.fnBody !== null) sgCollectRefsInNode(fd.fnBody, refs);
		return;
	}

	if (node.kind === NodeKind.InterfaceDecl) {
		const id = node.data as InterfaceDeclData;
		const ref: SgSymbolRef = { name: id.interfaceName, line: loc.line, col: loc.column, nameLen: id.interfaceName.length, isDecl: true };
		refs.push(ref);
		return;
	}

	if (node.kind === NodeKind.EnumDecl) {
		const ed = node.data as EnumDeclData;
		const ref: SgSymbolRef = { name: ed.enumName, line: loc.line, col: loc.column, nameLen: ed.enumName.length, isDecl: true };
		refs.push(ref);
		return;
	}

	if (node.kind === NodeKind.ClassDecl) {
		const cd = node.data as ClassDeclData;
		const ref: SgSymbolRef = { name: cd.className, line: loc.line, col: loc.column, nameLen: cd.className.length, isDecl: true };
		refs.push(ref);
		for (let ci = 0; ci < cd.classBody.length; ci = ci + 1) {
			sgCollectRefsInNode(cd.classBody[ci], refs);
		}
		return;
	}

	// Compound nodes — recurse into children
	sgCollectRefsInCompound(node, refs);
}

// Split out compound node recursion to avoid codegen function-size limits
function sgCollectRefsInCompound(node: Node, refs: SgSymbolRef[]): void {
	forEachChild(node, (child: Node): void => {
		sgCollectRefsInNode(child, refs);
	});
}

export function sgFindUsagesByName(refs: SgSymbolRef[], name: string): SgSymbolRef[] {
	const result: SgSymbolRef[] = [];
	for (let i = 0; i < refs.length; i = i + 1) {
		if (refs[i].name === name) {
			const r = refs[i];
			const ref: SgSymbolRef = { name: r.name, line: r.line, col: r.col, nameLen: r.nameLen, isDecl: r.isDecl };
			result.push(ref);
		}
	}
	return result;
}

// ===== Tests =====
test "number" { assert sgTypeToString(numberType()) === "number"; }

test "string" { assert sgTypeToString(stringType()) === "string"; }

test "boolean" { assert sgTypeToString(booleanType()) === "boolean"; }

test "void" { assert sgTypeToString(voidType()) === "void"; }

test "null" { assert sgTypeToString(nullType()) === "null"; }

test "unknown" { assert sgTypeToString(unknownType()) === "unknown"; }

test "never" { assert sgTypeToString(neverType()) === "never"; }

test "error" { assert sgTypeToString(errorType()) === "error"; }

import { createArray, createFunction, createEnum, createStruct, createResult } from "./types";
test "array" {
	const t = createArray(numberType());
	assert sgTypeToString(t) === "number[]";
}

test "function no params" {
	const params: Type[] = [];
	const names: string[] = [];
	const t = createFunction(params, names, voidType());
	assert sgTypeToString(t) === "() => void";
}

test "function with params" {
	const params: Type[] = [numberType(), stringType()];
	const names: string[] = ["a", "b"];
	const t = createFunction(params, names, booleanType());
	assert sgTypeToString(t) === "(a: number, b: string) => boolean";
}

test "enum" {
	const members: string[] = ["A", "B"];
	const t = createEnum("Color", members, null as unknown as number[]);
	assert sgTypeToString(t) === "Color";
}

test "named object" {
	const propNames: string[] = ["x", "y"];
	const propTypes: Type[] = [numberType(), numberType()];
	const t = createStruct("Point", propNames, propTypes, true);
	assert sgTypeToString(t) === "Point";
}

test "result" {
	const t = createResult(numberType(), stringType());
	assert sgTypeToString(t) === "Result<number, string>";
}

test "find identifier in simple decl" {
	const pr = parseSource("const x = 42;");
	if (!pr.ok) { assert false; return; }
	// "const x" - x is at col 6
	const node = sgFindNodeAtPosition(pr.value, 1, 6);
	assert node !== null;
}

test "find in function body" {
	const pr = parseSource("function foo() { return 1; }");
	if (!pr.ok) { assert false; return; }
	const node = sgFindNodeAtPosition(pr.value, 1, 17);
	assert node !== null;
}

test "returns null for null node" {
	const nullNode = null as unknown as Node;
	const node = sgFindNodeAtPosition(nullNode, 1, 0);
	assert node === null;
}

test "returns null for unknown position" {
	const pr = parseSource("const x = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const sg = sgGetSymbolAtCursor(ctx, pr.value, 100, 0);
	assert sg === null;
}

test "format variable hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "count", kind: SymbolKind.Variable, symType: numberType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	const hover = sgFormatHover(suggest);
	assert hover === "```ms\nconst count: number\n```";
}

test "format function hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const params: Type[] = [stringType()];
	const names: string[] = ["s"];
	const fnType = createFunction(params, names, voidType());
	const suggest: SgSuggest = {
		name: "greet", kind: SymbolKind.Function, symType: fnType,
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	const hover = sgFormatHover(suggest);
	assert hover === "```ms\nfunction greet(s: string): void\n```";
}

test "format interface hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "Point", kind: SymbolKind.Interface, symType: unknownType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	assert sgFormatHover(suggest) === "```ms\ninterface Point\n```";
}

test "format class hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "Vec", kind: SymbolKind.Class, symType: unknownType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	assert sgFormatHover(suggest) === "```ms\nclass Vec\n```";
}

test "format enum hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "Color", kind: SymbolKind.Enum, symType: unknownType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	assert sgFormatHover(suggest) === "```ms\nenum Color\n```";
}

test "format type alias hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "Id", kind: SymbolKind.TypeAlias, symType: numberType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	assert sgFormatHover(suggest) === "```ms\ntype Id = number\n```";
}

test "format let variable hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "x", kind: SymbolKind.Variable, symType: stringType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: true,
	};
	assert sgFormatHover(suggest) === "```ms\nlet x: string\n```";
}

test "format parameter hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "name", kind: SymbolKind.Parameter, symType: stringType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	assert sgFormatHover(suggest) === "```ms\n(parameter) name: string\n```";
}

test "format property hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "x", kind: SymbolKind.Property, symType: numberType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	assert sgFormatHover(suggest) === "```ms\n(property) x: number\n```";
}

test "format method hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const params: Type[] = [stringType()];
	const names: string[] = ["item"];
	const fnType = createFunction(params, names, voidType());
	const suggest: SgSuggest = {
		name: "push", kind: SymbolKind.Method, symType: fnType,
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	assert sgFormatHover(suggest) === "```ms\n(method) push(item: string): void\n```";
}

test "null suggest returns empty" {
	const sg = null as unknown as SgSuggest;
	assert sgFormatHover(sg) === "";
}

test "empty errors" {
	const pr = parseSource("const x = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const diags = sgCollectDiagnostics(ctx);
	assert diags.length === 0;
}

test "dot triggers MemberAccess" {
	// "foo.b" — cursor at col 5 (after 'b')
	assert sgDetectCompletionContext("foo.b", 1, 5) === SgCompletionKind.MemberAccess;
}

test "dot with no prefix" {
	// "foo." — cursor at col 4 (right after '.')
	assert sgDetectCompletionContext("foo.", 1, 4) === SgCompletionKind.MemberAccess;
}

test "colon triggers TypeAnnotation" {
	// "x: num" — cursor at col 6
	assert sgDetectCompletionContext("x: num", 1, 6) === SgCompletionKind.TypeAnnotation;
}

test "bare identifier" {
	// "con" — cursor at col 3
	assert sgDetectCompletionContext("con", 1, 3) === SgCompletionKind.Identifier;
}

test "start of line" { assert sgDetectCompletionContext("x", 1, 0) === SgCompletionKind.Identifier; }

test "extracts prefix" { assert sgGetPrefix("foo.bar", 1, 7) === "bar"; }

test "no prefix after dot" { assert sgGetPrefix("foo.", 1, 4) === ""; }

test "whole word" { assert sgGetPrefix("hello", 1, 5) === "hello"; }

test "empty at start" { assert sgGetPrefix("x", 1, 0) === ""; }

test "prefix with underscore" { assert sgGetPrefix("my_var", 1, 6) === "my_var"; }

test "second line" { assert sgGetPrefix("abc\ndef", 2, 3) === "def"; }

test "finds top-level symbols" {
	const pr = parseSource("const abc = 1;\nconst abd = 2;\nconst xyz = 3;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "ab", null);
	assert candidates.length === 2;
}

test "empty prefix returns all" {
	const pr = parseSource("const a = 1;\nconst b = 2;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "", null);
	assert candidates.length >= 2;
}

test "no match returns empty" {
	const pr = parseSource("const abc = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "zzz", null);
	assert candidates.length === 0;
}

test "only returns types" {
	const pr = parseSource("interface Foo { x: number; }\nconst y = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.TypeAnnotation, "", null);
	// Should include Foo (interface) but not y (variable)
	let hasFoo = false;
	let hasY = false;
	for (let i = 0; i < candidates.length; i = i + 1) {
		if (candidates[i].name === "Foo") hasFoo = true;
		if (candidates[i].name === "y") hasY = true;
	}
	assert hasFoo;
	assert !hasY;
}

test "object properties" {
	const propNames: string[] = ["x", "y", "z"];
	const propTypes: Type[] = [numberType(), numberType(), stringType()];
	const objType = createStruct("Point", propNames, propTypes, true);
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", objType);
	assert candidates.length === 3;
}

test "object properties with prefix" {
	const propNames: string[] = ["xPos", "yPos", "name"];
	const propTypes: Type[] = [numberType(), numberType(), stringType()];
	const objType = createStruct("Obj", propNames, propTypes, true);
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "x", objType);
	assert candidates.length === 1;
	assert candidates[0].name === "xPos";
}

test "enum members" {
	const members: string[] = ["Red", "Green", "Blue"];
	const enumType = createEnum("Color", members, null as unknown as number[]);
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", enumType);
	assert candidates.length === 3;
}

test "null receiver returns empty" {
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", null);
	assert candidates.length === 0;
}

test "exact prefix" { assert sgPrefixMatch("ab", "abc") === 2; }

test "substring" { assert sgPrefixMatch("bc", "abcd") === 1; }

test "no match" { assert sgPrefixMatch("zz", "abc") === 0; }

test "case insensitive prefix" { assert sgPrefixMatch("AB", "abcde") === 2; }

test "empty prefix" { assert sgPrefixMatch("", "anything") === 2; }

test "prefix before substr" {
	const pr = parseSource("const abcdef = 1;\nconst xyzabc = 2;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "abc", null);
	assert candidates.length === 2;
	// abcdef (prefix match) should come before xyzabc (substr match)
	assert candidates[0].name === "abcdef";
	assert candidates[1].name === "xyzabc";
}

test "inner scope before outer" {
	const pr = parseSource("const outer = 1;\nfunction f() { const inner = 2; }");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "", null);
	// inner scope (depth 0) should rank before outer scope (depth > 0)
	// At least both should be present
	assert candidates.length >= 2;
	// First items should have lower scopeDepth
	if (candidates.length >= 2) {
		assert candidates[0].scopeDepth <= candidates[1].scopeDepth;
	}
}

test "collects function and variable" {
	const pr = parseSource("function foo() { return 1; }\nconst x = 1;");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	assert symbols.length === 2;
	assert symbols[0].name === "foo";
	assert symbols[0].kind === SymbolKind.Function;
	assert symbols[1].name === "x";
	assert symbols[1].kind === SymbolKind.Variable;
}

test "collects interface and enum" {
	const pr = parseSource("interface Point { x: number; }\nenum Color { Red, Green }");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	assert symbols.length === 2;
	assert symbols[0].name === "Point";
	assert symbols[0].kind === SymbolKind.Interface;
	assert symbols[1].name === "Color";
	assert symbols[1].kind === SymbolKind.Enum;
}

test "unwraps export decl" {
	const pr = parseSource("export function bar() { return 1; }");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	assert symbols.length === 1;
	assert symbols[0].name === "bar";
}

test "empty program" {
	const pr = parseSource("");
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	assert symbols.length === 0;
}

test "function with params" {
	const params: Type[] = [numberType(), stringType()];
	const names: string[] = ["line", "msg"];
	const fnType = createFunction(params, names, voidType());
	const sym = makeSymbol("log", SymbolKind.Function, fnType, false);
	const sigs = sgFormatSignature(sym);
	assert sigs.length === 1;
	assert sigs[0].label === "log(line: number, msg: string): void";
	assert sigs[0].paramLabels.length === 2;
}

test "function no params" {
	const params: Type[] = [];
	const names: string[] = [];
	const fnType = createFunction(params, names, booleanType());
	const sym = makeSymbol("check", SymbolKind.Function, fnType, false);
	const sigs = sgFormatSignature(sym);
	assert sigs.length === 1;
	assert sigs[0].label === "check(): boolean";
	assert sigs[0].paramLabels.length === 0;
}

test "null symbol returns empty" {
	const nullSym = null as unknown as Symbol;
	const sigs = sgFormatSignature(nullSym);
	assert sigs.length === 0;
}

test "non-function symbol returns empty" {
	const sym = makeSymbol("x", SymbolKind.Variable, numberType(), false);
	const sigs = sgFormatSignature(sym);
	assert sigs.length === 0;
}

test "simple call" { assert sgGetCalleeAtCursor("foo(x", 1, 4) === "foo"; }

test "call with space before paren" { assert sgGetCalleeAtCursor("foo (x", 1, 5) === "foo"; }

test "nested call — inner" { assert sgGetCalleeAtCursor("foo(bar(x", 1, 8) === "bar"; }

test "not inside call returns empty" { assert sgGetCalleeAtCursor("hello", 1, 3) === ""; }

test "after comma" { assert sgGetCalleeAtCursor("add(1, 2", 1, 7) === "add"; }

test "first param" {
	// foo(| — cursor just after (
	assert sgCountActiveParam("foo(x", 1, 4) === 0;
}

test "second param" {
	// foo(a, | — cursor after comma
	assert sgCountActiveParam("foo(a, b", 1, 7) === 1;
}

test "third param" { assert sgCountActiveParam("foo(a, b, c", 1, 10) === 2; }

test "nested parens ignored" {
	// foo(bar(1, 2), | — inner commas don't count
	assert sgCountActiveParam("foo(bar(1, 2), x", 1, 15) === 1;
}

test "type hint for untyped variable" {
	const src = "const x = 42;";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	assert hints.length === 1;
	assert hints[0].label === ": number";
	assert hints[0].hintKind === SgInlayHintKind.Type;
}

test "no hint for explicitly typed variable" {
	const src = "const x: number = 42;";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	assert hints.length === 0;
}

test "parameter hints at call site" {
	const src = "function add(a: number, b: number): number { return a + b; }\nconst r = add(1, 2);";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	// Should have: type hint for r + param hints a: and b:
	let typeHints = 0;
	let paramHints = 0;
	for (let j = 0; j < hints.length; j = j + 1) {
		if (hints[j].hintKind === SgInlayHintKind.Type) { typeHints = typeHints + 1; }
		if (hints[j].hintKind === SgInlayHintKind.Parameter) { paramHints = paramHints + 1; }
	}
	assert typeHints >= 1;  // r: number
	assert paramHints === 2;  // a: 1, b: 2
}

test "skip param hint when arg matches param name" {
	const src = "function foo(x: number): void {}\nconst x = 5;\nfoo(x);";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	// x matches param name "x" — no param hint, just type hint for x
	let paramHints = 0;
	for (let j = 0; j < hints.length; j = j + 1) {
		if (hints[j].hintKind === SgInlayHintKind.Parameter) { paramHints = paramHints + 1; }
	}
	assert paramHints === 0;
}

test "collects declarations and usages" {
	const src = "const x = 1;\nconst y = x;";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const refs = sgCollectReferences(pr.value);
	// x: 1 decl + 1 usage, y: 1 decl
	assert refs.length >= 3;
}

test "find usages by name" {
	const src = "const x = 1;\nconst y = x;";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const refs = sgCollectReferences(pr.value);
	const xRefs = sgFindUsagesByName(refs, "x");
	assert xRefs.length === 2;
	// First should be decl, second should be usage
	assert xRefs[0].isDecl;
	assert !xRefs[1].isDecl;
}

test "function decl and call" {
	const src = "function greet(name: string): void {}\ngreet(\"hello\");";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const refs = sgCollectReferences(pr.value);
	const greetRefs = sgFindUsagesByName(refs, "greet");
	assert greetRefs.length === 2;
	assert greetRefs[0].isDecl;
	assert !greetRefs[1].isDecl;
}

test "no references for unknown name" {
	const src = "const x = 1;";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const refs = sgCollectReferences(pr.value);
	const noRefs = sgFindUsagesByName(refs, "nonexistent");
	assert noRefs.length === 0;
}

// ===== Doc Comment Tests =====

test "doc comment extraction" {
	const src = "// Adds two numbers\nfunction add(x: number): number { return x; }";
	const comment = sgExtractDocComment(src, 2);
	assert comment === "Adds two numbers";
}

test "doc comment multi-line" {
	const src = "// Line one\n// Line two\nfunction foo(): void {}";
	const comment = sgExtractDocComment(src, 3);
	assert comment === "Line one\nLine two";
}

test "doc comment stops at blank line" {
	const src = "// Orphaned\n\n// Real doc\nfunction bar(): void {}";
	const comment = sgExtractDocComment(src, 4);
	assert comment === "Real doc";
}

test "doc comment none" {
	const src = "const x = 1;\nfunction baz(): void {}";
	const comment = sgExtractDocComment(src, 2);
	assert comment === "";
}

test "doc comment first line no crash" {
	const src = "function first(): void {}";
	const comment = sgExtractDocComment(src, 1);
	assert comment === "";
}

test "doc comment with ## style" {
	const src = "## Standard reference style doc\nfunction foo(): void {}";
	const comment = sgExtractDocComment(src, 2);
	assert comment === "Standard reference style doc";
}

test "sgFormatHoverDoc with doc comment" {
	const suggest: SgSuggest = {
		name: "foo", kind: SymbolKind.Function,
		symType: unknownType(), location: { line: 1, column: 0 },
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: true, isMutable: false,
	};
	const doc = sgFormatHoverDoc(suggest, "A useful function");
	assert doc === "**exported**\n\n---\n\nA useful function";
}

test "sgFormatHoverDoc no comment" {
	const suggest: SgSuggest = {
		name: "bar", kind: SymbolKind.Variable,
		symType: unknownType(), location: { line: 1, column: 0 },
		prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	const doc = sgFormatHoverDoc(suggest, "");
	assert doc === "";
}

// ===== Import Source + Exported Decl Tests =====

test "find import source" {
	const src = "import { add } from \"./math\";\nconst x = add(1);";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	assert sgFindImportSource(pr.value, "add") === "./math";
}

test "find import source not found" {
	const src = "import { add } from \"./math\";";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	assert sgFindImportSource(pr.value, "unknown") === "";
}

test "find exported decl function" {
	const src = "export function add(x: number): number { return x; }";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const loc = sgFindExportedDecl(pr.value, "add");
	assert loc.line > 0;
}

test "find exported decl not found" {
	const src = "function add(x: number): number { return x; }";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const loc = sgFindExportedDecl(pr.value, "unknown");
	assert loc.line === 0;
}

test "exception hint for function returning Result" {
	const src = "function parse(s: string): Result<number, string> { return Result.ok(1); }";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	let exceptionCount = 0;
	for (let i = 0; i < hints.length; i = i + 1) {
		if (hints[i].hintKind === SgInlayHintKind.Exception) exceptionCount = exceptionCount + 1;
	}
	assert exceptionCount >= 1;
}

test "no exception hint for non-Result function" {
	const src = "function add(a: number, b: number): number { return a + b; }";
	const pr = parseSource(src);
	if (!pr.ok) { assert false; return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	let exceptionCount = 0;
	for (let i = 0; i < hints.length; i = i + 1) {
		if (hints[i].hintKind === SgInlayHintKind.Exception) exceptionCount = exceptionCount + 1;
	}
	assert exceptionCount === 0;
}
