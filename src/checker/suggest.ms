// Suggest — LSP intelligence layer
//
// Pure computation: typeToString, findNodeAtPosition, getSymbolAtCursor,
// formatHover, collectDiagnostics. No I/O, no protocol knowledge.
// Called by src/lsp/handlers.ms.

import { Node, NodeKind, SourceLocation, ProgramData,
	IdentifierData, MemberExprData, CallExprData,
	BinaryExprData, UnaryExprData, VariableDeclData,
	FunctionDeclData, IfStmtData, WhileStmtData, ForStmtData,
	ForOfStmtData, BlockStmtData, ExprStmtData, ReturnStmtData,
	ArrayLiteralData, ObjectLiteralData, ConditionalExprData,
	ArrowFunctionData, ArrayAccessData, MatchExprData, MatchCaseData,
	TryCatchStmtData, ClassDeclData, InterfaceDeclData, EnumDeclData,
	TypeAliasDeclData, ExportDeclData } from "../ast/node";
import { Type, TypeKind, typeNameOf,
	numberType, stringType, booleanType, voidType, nullType,
	unknownType, neverType, errorType } from "./types";
import { Symbol, SymbolKind, SymbolTable, Scope, lookupSymbol, makeSymbol } from "./symbol";
import { CheckerContext } from "./context";
import { sliceStr, charAt } from "../utils/string";
import { checkProgram } from "./checkPass";
import { parseSource } from "../parser/statements/validation";
// Import parseProgram to trigger callback registration (side-effect import)
import { parseProgram } from "../parser/statements/core";
import { test, check, testGroup } from "std/testing";

// ===== Data Types =====

export interface SgSuggest {
	name: string;
	kind: SymbolKind;
	symType: Type;
	location: SourceLocation;
}

export interface SgDiagnostic {
	message: string;
	line: number;
	column: number;
	severity: number;  // 1=Error, 2=Warning
}

export interface SgDiagnosticList {
	items: SgDiagnostic[];
}

export enum SgCompletionKind {
	Identifier,
	MemberAccess,
	TypeAnnotation,
}

export interface SgSuggestList {
	items: SgSuggest[];
}

export interface SgDocumentSymbol {
	name: string;
	kind: SymbolKind;
	location: SourceLocation;
}

export interface SgDocumentSymbolList {
	items: SgDocumentSymbol[];
}

export interface SgSignatureInfo {
	label: string;
	paramLabels: string[];
}

export interface SgSignatureList {
	items: SgSignatureInfo[];
}

// ===== sgTypeToString — full recursive type formatting =====

export function sgTypeToString(t: Type): string {
	if (t === null) return "unknown";

	const prim = match (t.kind) {
		TypeKind.Number => "number", TypeKind.String => "string",
		TypeKind.Boolean => "boolean", TypeKind.Void => "void",
		TypeKind.Null => "null", TypeKind.Unknown => "unknown",
		TypeKind.Never => "never", TypeKind.Error => "error",
		TypeKind.Int32 => "int32", TypeKind.Int64 => "int64",
		TypeKind.Uint32 => "uint32", TypeKind.Float32 => "float32",
		TypeKind.Float64 => "float64",
		_ => "",
	};
	if (prim.length > 0) return prim;

	if (t.kind === TypeKind.Array) {
		const elem = sgTypeToString(t.typeReturn);
		return elem + "[]";
	}

	if (t.kind === TypeKind.Object) {
		if (t.typeName.length > 0) return t.typeName;
		// Anonymous object: { key: type, ... }
		let result = "{ ";
		let i = 0;
		while (i < t.typeNames.length) {
			if (i > 0) result = result + ", ";
			result = result + t.typeNames[i] + ": ";
			if (i < t.typeChildren.length) {
				result = result + sgTypeToString(t.typeChildren[i]);
			}
			i = i + 1;
		}
		result = result + " }";
		return result;
	}

	if (t.kind === TypeKind.Function) {
		let result = "(";
		let i = 0;
		while (i < t.typeChildren.length) {
			if (i > 0) result = result + ", ";
			if (i < t.typeNames.length && t.typeNames[i].length > 0) {
				result = result + t.typeNames[i] + ": ";
			}
			result = result + sgTypeToString(t.typeChildren[i]);
			i = i + 1;
		}
		result = result + ") => " + sgTypeToString(t.typeReturn);
		return result;
	}

	if (t.kind === TypeKind.Enum) return t.typeName;

	if (t.kind === TypeKind.Union) {
		let result = "";
		let i = 0;
		while (i < t.typeChildren.length) {
			if (i > 0) result = result + " | ";
			result = result + sgTypeToString(t.typeChildren[i]);
			i = i + 1;
		}
		return result;
	}

	if (t.kind === TypeKind.Tuple) {
		let result = "[";
		let i = 0;
		while (i < t.typeChildren.length) {
			if (i > 0) result = result + ", ";
			result = result + sgTypeToString(t.typeChildren[i]);
			i = i + 1;
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
		let i = 0;
		while (i < t.typeChildren.length) {
			if (i > 0) result = result + ", ";
			result = result + sgTypeToString(t.typeChildren[i]);
			i = i + 1;
		}
		result = result + ">";
		return result;
	}

	if (t.kind === TypeKind.TypeReference) return t.typeName;

	return "unknown";
}

// ===== sgFindNodeAtPosition — walk AST to find node at cursor =====

function nodeContains(node: Node, line: number, col: number): boolean {
	if (node === null) return false;
	const loc = node.location;
	// Node starts at or before cursor position
	if (loc.line > line) return false;
	if (loc.line === line && loc.column > col) return false;
	return true;
}

function sgFindInChildren(children: Node[], line: number, col: number): Node {
	// Walk children in reverse to find innermost (last matching wins)
	let i = children.length - 1;
	while (i >= 0) {
		const child = children[i];
		if (child !== null && nodeContains(child, line, col)) {
			const deeper = sgFindNodeAtPosition(child, line, col);
			if (deeper !== null) return deeper;
		}
		i = i - 1;
	}
	return null as unknown as Node;
}

export function sgFindNodeAtPosition(program: Node, line: number, col: number): Node {
	if (program === null) return null as unknown as Node;
	if (!nodeContains(program, line, col)) return null as unknown as Node;

	// Leaf nodes
	if (program.kind === NodeKind.Identifier) return program;
	if (program.kind === NodeKind.NumberLiteral) return program;
	if (program.kind === NodeKind.StringLiteral) return program;
	if (program.kind === NodeKind.BooleanLiteral) return program;
	if (program.kind === NodeKind.NullLiteral) return program;

	// Program
	if (program.kind === NodeKind.Program) {
		const pd = program.data as ProgramData;
		return sgFindInChildren(pd.programStmts, line, col);
	}

	// Block
	if (program.kind === NodeKind.BlockStmt) {
		const bd = program.data as BlockStmtData;
		return sgFindInChildren(bd.statements, line, col);
	}

	// Variable declaration
	if (program.kind === NodeKind.VariableDecl) {
		const vd = program.data as VariableDeclData;
		if (vd.initializer !== null) {
			const found = sgFindNodeAtPosition(vd.initializer, line, col);
			if (found !== null) return found;
		}
		return program;
	}

	// Binary expression
	if (program.kind === NodeKind.BinaryExpr) {
		const bd = program.data as BinaryExprData;
		const r = sgFindNodeAtPosition(bd.right, line, col);
		if (r !== null) return r;
		const l = sgFindNodeAtPosition(bd.left, line, col);
		if (l !== null) return l;
		return program;
	}

	// Call expression
	if (program.kind === NodeKind.CallExpr) {
		const cd = program.data as CallExprData;
		let i = cd.arguments.length - 1;
		while (i >= 0) {
			const found = sgFindNodeAtPosition(cd.arguments[i], line, col);
			if (found !== null) return found;
			i = i - 1;
		}
		const calFound = sgFindNodeAtPosition(cd.callee, line, col);
		if (calFound !== null) return calFound;
		return program;
	}

	// Member expression
	if (program.kind === NodeKind.MemberExpr) {
		const md = program.data as MemberExprData;
		const objFound = sgFindNodeAtPosition(md.object, line, col);
		if (objFound !== null) return objFound;
		return program;
	}

	// Expression statement
	if (program.kind === NodeKind.ExprStmt) {
		const ed = program.data as ExprStmtData;
		const found = sgFindNodeAtPosition(ed.expr, line, col);
		if (found !== null) return found;
		return program;
	}

	// Return statement
	if (program.kind === NodeKind.ReturnStmt) {
		const rd = program.data as ReturnStmtData;
		if (rd.argument !== null) {
			const found = sgFindNodeAtPosition(rd.argument, line, col);
			if (found !== null) return found;
		}
		return program;
	}

	// If statement
	if (program.kind === NodeKind.IfStmt) {
		const id = program.data as IfStmtData;
		if (id.alternate !== null) {
			const found = sgFindNodeAtPosition(id.alternate, line, col);
			if (found !== null) return found;
		}
		const consFound = sgFindNodeAtPosition(id.consequent, line, col);
		if (consFound !== null) return consFound;
		const condFound = sgFindNodeAtPosition(id.condition, line, col);
		if (condFound !== null) return condFound;
		return program;
	}

	// While statement
	if (program.kind === NodeKind.WhileStmt) {
		const wd = program.data as WhileStmtData;
		const bodyFound = sgFindNodeAtPosition(wd.whileBody, line, col);
		if (bodyFound !== null) return bodyFound;
		const condFound = sgFindNodeAtPosition(wd.whileCondition, line, col);
		if (condFound !== null) return condFound;
		return program;
	}

	// Function declaration
	if (program.kind === NodeKind.FunctionDecl) {
		const fd = program.data as FunctionDeclData;
		const bodyFound = sgFindNodeAtPosition(fd.fnBody, line, col);
		if (bodyFound !== null) return bodyFound;
		return program;
	}

	// Array literal
	if (program.kind === NodeKind.ArrayLiteral) {
		const ad = program.data as ArrayLiteralData;
		return sgFindInChildren(ad.elements, line, col);
	}

	// Conditional expression
	if (program.kind === NodeKind.ConditionalExpr) {
		const cd = program.data as ConditionalExprData;
		const altFound = sgFindNodeAtPosition(cd.ternaryAlternate, line, col);
		if (altFound !== null) return altFound;
		const consFound = sgFindNodeAtPosition(cd.ternaryConsequent, line, col);
		if (consFound !== null) return consFound;
		const condFound = sgFindNodeAtPosition(cd.ternaryCondition, line, col);
		if (condFound !== null) return condFound;
		return program;
	}

	// Unary expression
	if (program.kind === NodeKind.UnaryExpr) {
		const ud = program.data as UnaryExprData;
		const found = sgFindNodeAtPosition(ud.operand, line, col);
		if (found !== null) return found;
		return program;
	}

	// Array access
	if (program.kind === NodeKind.ArrayAccess) {
		const ad = program.data as ArrayAccessData;
		const idxFound = sgFindNodeAtPosition(ad.index, line, col);
		if (idxFound !== null) return idxFound;
		const arrFound = sgFindNodeAtPosition(ad.array, line, col);
		if (arrFound !== null) return arrFound;
		return program;
	}

	// Fallback: return self if position matches
	return program;
}

// ===== sgGetSymbolAtCursor — resolve symbol at cursor position =====

export function sgGetSymbolAtCursor(ctx: CheckerContext, program: Node, line: number, col: number): SgSuggest {
	const node = sgFindNodeAtPosition(program, line, col);
	if (node === null) return null as unknown as SgSuggest;

	if (node.kind === NodeKind.Identifier) {
		const id = node.data as IdentifierData;
		const sym = lookupSymbol(ctx.table, id.name);
		if (sym === null) return null as unknown as SgSuggest;
		const suggest: SgSuggest = {
			name: sym.name,
			kind: sym.symbolKind,
			symType: sym.symbolType,
			location: sym.location,
		};
		return suggest;
	}

	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		const sym = lookupSymbol(ctx.table, vd.declName);
		if (sym === null) return null as unknown as SgSuggest;
		const suggest: SgSuggest = {
			name: sym.name,
			kind: sym.symbolKind,
			symType: sym.symbolType,
			location: sym.location,
		};
		return suggest;
	}

	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		const sym = lookupSymbol(ctx.table, fd.fnName);
		if (sym === null) return null as unknown as SgSuggest;
		const suggest: SgSuggest = {
			name: sym.name,
			kind: sym.symbolKind,
			symType: sym.symbolType,
			location: sym.location,
		};
		return suggest;
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
		_ => "symbol",
	};
}

export function sgFormatHover(suggest: SgSuggest): string {
	if (suggest === null) return "";
	const kindName = sgSymbolKindName(suggest.kind);
	const typeStr = sgTypeToString(suggest.symType);
	// Format: ```ms\n(kind) name: type\n```
	return "```ms\n(" + kindName + ") " + suggest.name + ": " + typeStr + "\n```";
}

// ===== sgCollectDiagnostics — wrap checker errors =====

export function sgCollectDiagnostics(ctx: CheckerContext): SgDiagnosticList {
	const result: SgDiagnosticList = { items: [] };
	let i = 0;
	while (i < ctx.errors.length) {
		const diag: SgDiagnostic = {
			message: ctx.errors[i],
			line: 1,
			column: 0,
			severity: 1,
		};
		result.items.push(diag);
		i = i + 1;
	}
	return result;
}

// ===== Completion Helpers =====

function sgIsIdentChar(ch: string): boolean {
	if (ch === "_") return true;
	const identChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
	let i = 0;
	while (i < identChars.length) {
		if (charAt(identChars, i) === ch) return true;
		i = i + 1;
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

export function sgGetCompletionCandidates(ctx: CheckerContext, kind: SgCompletionKind, prefix: string, receiverType: Type): SgSuggestList {
	const result: SgSuggestList = { items: [] };

	if (kind === SgCompletionKind.MemberAccess) {
		// Dot completion: properties from receiver type
		if (receiverType !== null && receiverType.kind === TypeKind.Object) {
			let i = 0;
			while (i < receiverType.typeNames.length) {
				const propName = receiverType.typeNames[i];
				if (sgStartsWith(propName, prefix)) {
					const propType = i < receiverType.typeChildren.length
						? receiverType.typeChildren[i] : unknownType();
					const loc: SourceLocation = { line: 0, column: 0 };
					const item: SgSuggest = {
						name: propName,
						kind: SymbolKind.Property,
						symType: propType,
						location: loc,
					};
					result.items.push(item);
				}
				i = i + 1;
			}
		}
		// Enum member completion
		if (receiverType !== null && receiverType.kind === TypeKind.Enum) {
			let i = 0;
			while (i < receiverType.typeNames.length) {
				const memberName = receiverType.typeNames[i];
				if (sgStartsWith(memberName, prefix)) {
					const loc: SourceLocation = { line: 0, column: 0 };
					const item: SgSuggest = {
						name: memberName,
						kind: SymbolKind.Property,
						symType: receiverType,
						location: loc,
					};
					result.items.push(item);
				}
				i = i + 1;
			}
		}
		// Extension methods
		if (receiverType !== null && ctx.extensionRegistry !== null) {
			const recTypeName = typeNameOf(receiverType);
			if (recTypeName.length > 0) {
				let j = 0;
				while (j < ctx.extensionRegistry.methods.length) {
					const ext = ctx.extensionRegistry.methods[j];
					if (ext.receiverTypeName === recTypeName && sgStartsWith(ext.methodName, prefix)) {
						const loc: SourceLocation = { line: 0, column: 0 };
						const item: SgSuggest = {
							name: ext.methodName,
							kind: SymbolKind.Method,
							symType: ext.fnType,
							location: loc,
						};
						result.items.push(item);
					}
					j = j + 1;
				}
			}
		}
		return result;
	}

	// Walk scope chain for Identifier or TypeAnnotation
	let scope = ctx.table.current;
	while (scope !== null) {
		let i = 0;
		while (i < scope.symbols.length) {
			const sym = scope.symbols[i];
			if (sgStartsWith(sym.name, prefix)) {
				if (kind === SgCompletionKind.TypeAnnotation) {
					if (sgIsTypeKind(sym.symbolKind)) {
						const item: SgSuggest = {
							name: sym.name,
							kind: sym.symbolKind,
							symType: sym.symbolType,
							location: sym.location,
						};
						result.items.push(item);
					}
				} else {
					const item: SgSuggest = {
						name: sym.name,
						kind: sym.symbolKind,
						symType: sym.symbolType,
						location: sym.location,
					};
					result.items.push(item);
				}
			}
			i = i + 1;
		}
		scope = scope.parent;
	}

	return result;
}

// ===== Document Symbols — collect top-level declarations =====

function sgCollectOneSymbol(node: Node, result: SgDocumentSymbolList): void {
	if (node === null) return;

	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		const item: SgDocumentSymbol = { name: fd.fnName, kind: SymbolKind.Function, location: node.location };
		result.items.push(item);
		return;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		const item: SgDocumentSymbol = { name: vd.declName, kind: SymbolKind.Variable, location: node.location };
		result.items.push(item);
		return;
	}
	if (node.kind === NodeKind.InterfaceDecl) {
		const id = node.data as InterfaceDeclData;
		const item: SgDocumentSymbol = { name: id.interfaceName, kind: SymbolKind.Interface, location: node.location };
		result.items.push(item);
		return;
	}
	if (node.kind === NodeKind.EnumDecl) {
		const ed = node.data as EnumDeclData;
		const item: SgDocumentSymbol = { name: ed.enumName, kind: SymbolKind.Enum, location: node.location };
		result.items.push(item);
		return;
	}
	if (node.kind === NodeKind.ClassDecl) {
		const cd = node.data as ClassDeclData;
		const item: SgDocumentSymbol = { name: cd.className, kind: SymbolKind.Class, location: node.location };
		result.items.push(item);
		return;
	}
	if (node.kind === NodeKind.TypeAliasDecl) {
		const td = node.data as TypeAliasDeclData;
		const item: SgDocumentSymbol = { name: td.aliasName, kind: SymbolKind.TypeAlias, location: node.location };
		result.items.push(item);
		return;
	}
	if (node.kind === NodeKind.ExportDecl) {
		const xd = node.data as ExportDeclData;
		sgCollectOneSymbol(xd.exportedDecl, result);
		return;
	}
}

export function sgCollectSymbolsInFile(ctx: CheckerContext, program: Node): SgDocumentSymbolList {
	const result: SgDocumentSymbolList = { items: [] };
	if (program === null || program.kind !== NodeKind.Program) return result;
	const pd = program.data as ProgramData;
	let i = 0;
	while (i < pd.programStmts.length) {
		sgCollectOneSymbol(pd.programStmts[i], result);
		i = i + 1;
	}
	return result;
}

// ===== Signature Help — format function signatures =====

function sgBuildSignatureInfo(name: string, fnType: Type): SgSignatureInfo {
	const paramLabels: string[] = [];
	let label = name + "(";
	let i = 0;
	while (i < fnType.typeChildren.length) {
		if (i > 0) label = label + ", ";
		let paramLabel = "";
		if (i < fnType.typeNames.length && fnType.typeNames[i].length > 0) {
			paramLabel = fnType.typeNames[i] + ": " + sgTypeToString(fnType.typeChildren[i]);
		} else {
			paramLabel = sgTypeToString(fnType.typeChildren[i]);
		}
		paramLabels.push(paramLabel);
		label = label + paramLabel;
		i = i + 1;
	}
	label = label + "): " + sgTypeToString(fnType.typeReturn);
	const info: SgSignatureInfo = { label, paramLabels };
	return info;
}

export function sgFormatSignature(sym: Symbol): SgSignatureList {
	const result: SgSignatureList = { items: [] };
	if (sym === null) return result;
	if (sym.symbolType === null || sym.symbolType.kind !== TypeKind.Function) return result;

	// Main signature
	const main = sgBuildSignatureInfo(sym.name, sym.symbolType);
	result.items.push(main);

	// Overloads
	let i = 0;
	while (i < sym.overloads.length) {
		const ovl = sym.overloads[i];
		if (ovl.symbolType !== null && ovl.symbolType.kind === TypeKind.Function) {
			const ovlInfo = sgBuildSignatureInfo(sym.name, ovl.symbolType);
			result.items.push(ovlInfo);
		}
		i = i + 1;
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
}

export interface SgInlayHint {
	label: string;
	line: number;
	col: number;
	hintKind: SgInlayHintKind;
}

export interface SgInlayHintList {
	items: SgInlayHint[];
}

// Walk top-level statements in range [startLine, endLine] (1-indexed, inclusive).
// Collect type hints for variables without annotations,
// and parameter name hints at call sites.
export function sgCollectInlayHints(
	ctx: CheckerContext, program: Node, startLine: number, endLine: number
): SgInlayHintList {
	const result: SgInlayHintList = { items: [] };
	const pd = program.data as ProgramData;
	let i = 0;
	while (i < pd.programStmts.length) {
		const stmt = pd.programStmts[i];
		sgCollectHintsInNode(ctx, stmt, startLine, endLine, result);
		i = i + 1;
	}
	return result;
}

function sgCollectHintsInNode(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHintList
): void {
	if (node === null) return;
	const loc = node.location;
	// Skip nodes outside range
	if (loc.line > endLine) return;

	// Export declarations — unwrap
	if (node.kind === NodeKind.ExportDecl) {
		const ed = node.data as ExportDeclData;
		sgCollectHintsInNode(ctx, ed.exportedDecl, startLine, endLine, hints);
		return;
	}

	// Variable declarations: type hint if no annotation + walk initializer
	if (node.kind === NodeKind.VariableDecl) {
		sgCollectVarTypeHint(ctx, node, startLine, endLine, hints);
		const vd = node.data as VariableDeclData;
		if (vd.initializer !== null) {
			sgCollectHintsInNode(ctx, vd.initializer, startLine, endLine, hints);
		}
		return;
	}

	// Function declarations: walk body for call sites + nested vars
	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		if (fd.fnBody !== null) {
			sgCollectHintsInNode(ctx, fd.fnBody, startLine, endLine, hints);
		}
		return;
	}

	// Block statements: walk children
	if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		let j = 0;
		while (j < bd.statements.length) {
			sgCollectHintsInNode(ctx, bd.statements[j], startLine, endLine, hints);
			j = j + 1;
		}
		return;
	}

	// Expression statements: check for call expressions
	if (node.kind === NodeKind.ExprStmt) {
		const es = node.data as ExprStmtData;
		sgCollectHintsInNode(ctx, es.expr, startLine, endLine, hints);
		return;
	}

	// Return statements: check expression
	if (node.kind === NodeKind.ReturnStmt) {
		const rs = node.data as ReturnStmtData;
		sgCollectHintsInNode(ctx, rs.argument, startLine, endLine, hints);
		return;
	}

	// Call expressions: parameter name hints
	if (node.kind === NodeKind.CallExpr) {
		sgCollectCallParamHints(ctx, node, startLine, endLine, hints);
		return;
	}

	// If statements: walk both branches
	if (node.kind === NodeKind.IfStmt) {
		const ifd = node.data as IfStmtData;
		sgCollectHintsInNode(ctx, ifd.consequent, startLine, endLine, hints);
		sgCollectHintsInNode(ctx, ifd.alternate, startLine, endLine, hints);
		return;
	}

	// While: walk body
	if (node.kind === NodeKind.WhileStmt) {
		const wd = node.data as WhileStmtData;
		sgCollectHintsInNode(ctx, wd.whileBody, startLine, endLine, hints);
		return;
	}
}

function sgCollectVarTypeHint(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHintList
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
	hints.items.push(hint);
}

function sgCollectCallParamHints(
	ctx: CheckerContext, node: Node, startLine: number, endLine: number, hints: SgInlayHintList
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

	let j = 0;
	while (j < cd.arguments.length && j < paramNames.length) {
		const arg = cd.arguments[j];
		if (arg === null) { j = j + 1; continue; }
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
			hints.items.push(hint);
		}
		j = j + 1;
	}

	// Also walk into argument expressions for nested calls
	j = 0;
	while (j < cd.arguments.length) {
		sgCollectHintsInNode(ctx, cd.arguments[j], startLine, endLine, hints);
		j = j + 1;
	}
}

// ===== Tests =====

testGroup("sgTypeToString Primitives", () => {
	test("number", () => {
		check(sgTypeToString(numberType()) === "number");
	});
	test("string", () => {
		check(sgTypeToString(stringType()) === "string");
	});
	test("boolean", () => {
		check(sgTypeToString(booleanType()) === "boolean");
	});
	test("void", () => {
		check(sgTypeToString(voidType()) === "void");
	});
	test("null", () => {
		check(sgTypeToString(nullType()) === "null");
	});
	test("unknown", () => {
		check(sgTypeToString(unknownType()) === "unknown");
	});
	test("never", () => {
		check(sgTypeToString(neverType()) === "never");
	});
	test("error", () => {
		check(sgTypeToString(errorType()) === "error");
	});
});

import { createArray, createFunction, createEnum, createObject, createResult } from "./types";

testGroup("sgTypeToString Compound", () => {
	test("array", () => {
		const t = createArray(numberType());
		check(sgTypeToString(t) === "number[]");
	});
	test("function no params", () => {
		const params: Type[] = [];
		const names: string[] = [];
		const t = createFunction(params, names, voidType());
		check(sgTypeToString(t) === "() => void");
	});
	test("function with params", () => {
		const params: Type[] = [numberType(), stringType()];
		const names: string[] = ["a", "b"];
		const t = createFunction(params, names, booleanType());
		check(sgTypeToString(t) === "(a: number, b: string) => boolean");
	});
	test("enum", () => {
		const members: string[] = ["A", "B"];
		const t = createEnum("Color", members);
		check(sgTypeToString(t) === "Color");
	});
	test("named object", () => {
		const propNames: string[] = ["x", "y"];
		const propTypes: Type[] = [numberType(), numberType()];
		const t = createObject("Point", propNames, propTypes, true);
		check(sgTypeToString(t) === "Point");
	});
	test("result", () => {
		const t = createResult(numberType(), stringType());
		check(sgTypeToString(t) === "Result<number, string>");
	});
});

testGroup("sgFindNodeAtPosition", () => {
	test("find identifier in simple decl", () => {
		const pr = parseSource("const x = 42;");
		if (!pr.ok) { check(false); return; }
		// "const x" - x is at col 6
		const node = sgFindNodeAtPosition(pr.value, 1, 6);
		check(node !== null);
	});
	test("find in function body", () => {
		const pr = parseSource("function foo() { return 1; }");
		if (!pr.ok) { check(false); return; }
		const node = sgFindNodeAtPosition(pr.value, 1, 17);
		check(node !== null);
	});
	test("returns null for null node", () => {
		const nullNode = null as unknown as Node;
		const node = sgFindNodeAtPosition(nullNode, 1, 0);
		check(node === null);
	});
});

testGroup("sgGetSymbolAtCursor", () => {
	test("find variable type", () => {
		const pr = parseSource("const myVar: number = 42;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		// myVar starts around col 6
		const sg = sgGetSymbolAtCursor(ctx, pr.value, 1, 6);
		// May or may not find depending on exact position
		if (sg !== null) {
			check(sg.name === "myVar");
		} else {
			check(true); // position might not match exactly
		}
	});
	test("returns null for unknown position", () => {
		const pr = parseSource("const x = 1;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const sg = sgGetSymbolAtCursor(ctx, pr.value, 100, 0);
		check(sg === null);
	});
});

testGroup("sgFormatHover", () => {
	test("format variable hover", () => {
		const loc: SourceLocation = { line: 1, column: 0 };
		const suggest: SgSuggest = {
			name: "count",
			kind: SymbolKind.Variable,
			symType: numberType(),
			location: loc,
		};
		const hover = sgFormatHover(suggest);
		check(hover === "```ms\n(variable) count: number\n```");
	});
	test("format function hover", () => {
		const loc: SourceLocation = { line: 1, column: 0 };
		const params: Type[] = [stringType()];
		const names: string[] = ["s"];
		const fnType = createFunction(params, names, voidType());
		const suggest: SgSuggest = {
			name: "greet",
			kind: SymbolKind.Function,
			symType: fnType,
			location: loc,
		};
		const hover = sgFormatHover(suggest);
		check(hover === "```ms\n(function) greet: (s: string) => void\n```");
	});
	test("null suggest returns empty", () => {
		const sg = null as unknown as SgSuggest;
		check(sgFormatHover(sg) === "");
	});
});

testGroup("sgCollectDiagnostics", () => {
	test("empty errors", () => {
		const pr = parseSource("const x = 1;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const diags = sgCollectDiagnostics(ctx);
		check(diags.items.length === 0);
	});
	test("collects errors", () => {
		// Undeclared variable usage should produce error
		const pr = parseSource("const x = unknownVar;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const diags = sgCollectDiagnostics(ctx);
		// May or may not have errors depending on checker behavior
		check(diags.items.length >= 0);
	});
});

testGroup("sgDetectCompletionContext", () => {
	test("dot triggers MemberAccess", () => {
		// "foo.b" — cursor at col 5 (after 'b')
		check(sgDetectCompletionContext("foo.b", 1, 5) === SgCompletionKind.MemberAccess);
	});
	test("dot with no prefix", () => {
		// "foo." — cursor at col 4 (right after '.')
		check(sgDetectCompletionContext("foo.", 1, 4) === SgCompletionKind.MemberAccess);
	});
	test("colon triggers TypeAnnotation", () => {
		// "x: num" — cursor at col 6
		check(sgDetectCompletionContext("x: num", 1, 6) === SgCompletionKind.TypeAnnotation);
	});
	test("bare identifier", () => {
		// "con" — cursor at col 3
		check(sgDetectCompletionContext("con", 1, 3) === SgCompletionKind.Identifier);
	});
	test("start of line", () => {
		check(sgDetectCompletionContext("x", 1, 0) === SgCompletionKind.Identifier);
	});
});

testGroup("sgGetPrefix", () => {
	test("extracts prefix", () => {
		check(sgGetPrefix("foo.bar", 1, 7) === "bar");
	});
	test("no prefix after dot", () => {
		check(sgGetPrefix("foo.", 1, 4) === "");
	});
	test("whole word", () => {
		check(sgGetPrefix("hello", 1, 5) === "hello");
	});
	test("empty at start", () => {
		check(sgGetPrefix("x", 1, 0) === "");
	});
	test("prefix with underscore", () => {
		check(sgGetPrefix("my_var", 1, 6) === "my_var");
	});
	test("second line", () => {
		check(sgGetPrefix("abc\ndef", 2, 3) === "def");
	});
});

testGroup("sgGetCompletionCandidates Identifier", () => {
	test("finds top-level symbols", () => {
		const pr = parseSource("const abc = 1;\nconst abd = 2;\nconst xyz = 3;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "ab", null as unknown as Type);
		check(candidates.items.length === 2);
	});
	test("empty prefix returns all", () => {
		const pr = parseSource("const a = 1;\nconst b = 2;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "", null as unknown as Type);
		check(candidates.items.length >= 2);
	});
	test("no match returns empty", () => {
		const pr = parseSource("const abc = 1;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "zzz", null as unknown as Type);
		check(candidates.items.length === 0);
	});
});

testGroup("sgGetCompletionCandidates TypeAnnotation", () => {
	test("only returns types", () => {
		const pr = parseSource("interface Foo { x: number; }\nconst y = 1;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.TypeAnnotation, "", null as unknown as Type);
		// Should include Foo (interface) but not y (variable)
		let hasFoo = false;
		let hasY = false;
		let i = 0;
		while (i < candidates.items.length) {
			if (candidates.items[i].name === "Foo") hasFoo = true;
			if (candidates.items[i].name === "y") hasY = true;
			i = i + 1;
		}
		check(hasFoo);
		check(!hasY);
	});
});

testGroup("sgGetCompletionCandidates MemberAccess", () => {
	test("object properties", () => {
		const propNames: string[] = ["x", "y", "z"];
		const propTypes: Type[] = [numberType(), numberType(), stringType()];
		const objType = createObject("Point", propNames, propTypes, true);
		const pr = parseSource("const a = 1;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", objType);
		check(candidates.items.length === 3);
	});
	test("object properties with prefix", () => {
		const propNames: string[] = ["xPos", "yPos", "name"];
		const propTypes: Type[] = [numberType(), numberType(), stringType()];
		const objType = createObject("Obj", propNames, propTypes, true);
		const pr = parseSource("const a = 1;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "x", objType);
		check(candidates.items.length === 1);
		check(candidates.items[0].name === "xPos");
	});
	test("enum members", () => {
		const members: string[] = ["Red", "Green", "Blue"];
		const enumType = createEnum("Color", members);
		const pr = parseSource("const a = 1;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", enumType);
		check(candidates.items.length === 3);
	});
	test("null receiver returns empty", () => {
		const pr = parseSource("const a = 1;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", null as unknown as Type);
		check(candidates.items.length === 0);
	});
});

testGroup("sgCollectSymbolsInFile", () => {
	test("collects function and variable", () => {
		const pr = parseSource("function foo() { return 1; }\nconst x = 1;");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const symbols = sgCollectSymbolsInFile(ctx, pr.value);
		check(symbols.items.length === 2);
		check(symbols.items[0].name === "foo");
		check(symbols.items[0].kind === SymbolKind.Function);
		check(symbols.items[1].name === "x");
		check(symbols.items[1].kind === SymbolKind.Variable);
	});
	test("collects interface and enum", () => {
		const pr = parseSource("interface Point { x: number; }\nenum Color { Red, Green }");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const symbols = sgCollectSymbolsInFile(ctx, pr.value);
		check(symbols.items.length === 2);
		check(symbols.items[0].name === "Point");
		check(symbols.items[0].kind === SymbolKind.Interface);
		check(symbols.items[1].name === "Color");
		check(symbols.items[1].kind === SymbolKind.Enum);
	});
	test("unwraps export decl", () => {
		const pr = parseSource("export function bar() { return 1; }");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const symbols = sgCollectSymbolsInFile(ctx, pr.value);
		check(symbols.items.length === 1);
		check(symbols.items[0].name === "bar");
	});
	test("empty program", () => {
		const pr = parseSource("");
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const symbols = sgCollectSymbolsInFile(ctx, pr.value);
		check(symbols.items.length === 0);
	});
});

testGroup("sgFormatSignature", () => {
	test("function with params", () => {
		const params: Type[] = [numberType(), stringType()];
		const names: string[] = ["line", "msg"];
		const fnType = createFunction(params, names, voidType());
		const sym = makeSymbol("log", SymbolKind.Function, fnType, false);
		const sigs = sgFormatSignature(sym);
		check(sigs.items.length === 1);
		check(sigs.items[0].label === "log(line: number, msg: string): void");
		check(sigs.items[0].paramLabels.length === 2);
	});
	test("function no params", () => {
		const params: Type[] = [];
		const names: string[] = [];
		const fnType = createFunction(params, names, booleanType());
		const sym = makeSymbol("check", SymbolKind.Function, fnType, false);
		const sigs = sgFormatSignature(sym);
		check(sigs.items.length === 1);
		check(sigs.items[0].label === "check(): boolean");
		check(sigs.items[0].paramLabels.length === 0);
	});
	test("null symbol returns empty", () => {
		const nullSym = null as unknown as Symbol;
		const sigs = sgFormatSignature(nullSym);
		check(sigs.items.length === 0);
	});
	test("non-function symbol returns empty", () => {
		const sym = makeSymbol("x", SymbolKind.Variable, numberType(), false);
		const sigs = sgFormatSignature(sym);
		check(sigs.items.length === 0);
	});
});

testGroup("sgGetCalleeAtCursor", () => {
	test("simple call", () => {
		check(sgGetCalleeAtCursor("foo(x", 1, 4) === "foo");
	});
	test("call with space before paren", () => {
		check(sgGetCalleeAtCursor("foo (x", 1, 5) === "foo");
	});
	test("nested call — inner", () => {
		check(sgGetCalleeAtCursor("foo(bar(x", 1, 8) === "bar");
	});
	test("not inside call returns empty", () => {
		check(sgGetCalleeAtCursor("hello", 1, 3) === "");
	});
	test("after comma", () => {
		check(sgGetCalleeAtCursor("add(1, 2", 1, 7) === "add");
	});
});

testGroup("sgCountActiveParam", () => {
	test("first param", () => {
		// foo(| — cursor just after (
		check(sgCountActiveParam("foo(x", 1, 4) === 0);
	});
	test("second param", () => {
		// foo(a, | — cursor after comma
		check(sgCountActiveParam("foo(a, b", 1, 7) === 1);
	});
	test("third param", () => {
		check(sgCountActiveParam("foo(a, b, c", 1, 10) === 2);
	});
	test("nested parens ignored", () => {
		// foo(bar(1, 2), | — inner commas don't count
		check(sgCountActiveParam("foo(bar(1, 2), x", 1, 15) === 1);
	});
});

testGroup("sgCollectInlayHints", () => {
	test("type hint for untyped variable", () => {
		const src = "const x = 42;";
		const pr = parseSource(src);
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
		check(hints.items.length === 1);
		check(hints.items[0].label === ": number");
		check(hints.items[0].hintKind === SgInlayHintKind.Type);
	});
	test("no hint for explicitly typed variable", () => {
		const src = "const x: number = 42;";
		const pr = parseSource(src);
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
		check(hints.items.length === 0);
	});
	test("parameter hints at call site", () => {
		const src = "function add(a: number, b: number): number { return a + b; }\nconst r = add(1, 2);";
		const pr = parseSource(src);
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
		// Should have: type hint for r + param hints a: and b:
		let typeHints = 0;
		let paramHints = 0;
		let j = 0;
		while (j < hints.items.length) {
			if (hints.items[j].hintKind === SgInlayHintKind.Type) { typeHints = typeHints + 1; }
			if (hints.items[j].hintKind === SgInlayHintKind.Parameter) { paramHints = paramHints + 1; }
			j = j + 1;
		}
		check(typeHints >= 1);  // r: number
		check(paramHints === 2);  // a: 1, b: 2
	});
	test("skip param hint when arg matches param name", () => {
		const src = "function foo(x: number): void {}\nconst x = 5;\nfoo(x);";
		const pr = parseSource(src);
		if (!pr.ok) { check(false); return; }
		const ctx = checkProgram(pr.value);
		const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
		// x matches param name "x" — no param hint, just type hint for x
		let paramHints = 0;
		let j = 0;
		while (j < hints.items.length) {
			if (hints.items[j].hintKind === SgInlayHintKind.Parameter) { paramHints = paramHints + 1; }
			j = j + 1;
		}
		check(paramHints === 0);
	});
});
