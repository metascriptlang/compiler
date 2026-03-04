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
import { Symbol, SymbolKind, SymbolTable, Scope, lookupSymbol, makeSymbol, hasFlag, SF_EXPORTED, SF_MUTABLE } from "./symbol";
import { CheckerContext } from "./context";
import { sliceStr, charAt } from "../utils/string";
import { checkProgram } from "./checkPass";
import { parseSource } from "../parser/statements/validation";
// Import parseProgram to trigger callback registration (side-effect import)
import { parseProgram } from "../parser/statements/core";
import { check } from "std/testing";

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
	for (let i = children.length - 1; i >= 0; i = i - 1) {
		const child = children[i];
		if (child !== null && nodeContains(child, line, col)) {
			const deeper = sgFindNodeAtPosition(child, line, col);
			if (deeper !== null) return deeper;
		}
	}
	return null as unknown as Node;
}

export function sgFindNodeAtPosition(program: Node, line: number, col: number): Node {
	if (program === null) return null as unknown as Node;
	if (!nodeContains(program, line, col)) return null as unknown as Node;

	// Leaf nodes
	if (program.kind === NodeKind.Identifier
		|| program.kind === NodeKind.NumberLiteral
		|| program.kind === NodeKind.StringLiteral
		|| program.kind === NodeKind.BooleanLiteral
		|| program.kind === NodeKind.NullLiteral) return program;

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
		for (let i = cd.arguments.length - 1; i >= 0; i = i - 1) {
			const found = sgFindNodeAtPosition(cd.arguments[i], line, col);
			if (found !== null) return found;
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
			name: sym.name, kind: sym.symbolKind, symType: sym.symbolType,
			location: sym.location, prefixScore: 0, scopeDepth: 0, contextFit: false,
			isExported: hasFlag(sym, SF_EXPORTED), isMutable: hasFlag(sym, SF_MUTABLE),
		};
		return suggest;
	}

	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		const sym = lookupSymbol(ctx.table, vd.declName);
		if (sym === null) return null as unknown as SgSuggest;
		const suggest: SgSuggest = {
			name: sym.name, kind: sym.symbolKind, symType: sym.symbolType,
			location: sym.location, prefixScore: 0, scopeDepth: 0, contextFit: false,
			isExported: hasFlag(sym, SF_EXPORTED), isMutable: hasFlag(sym, SF_MUTABLE),
		};
		return suggest;
	}

	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		const sym = lookupSymbol(ctx.table, fd.fnName);
		if (sym === null) return null as unknown as SgSuggest;
		const suggest: SgSuggest = {
			name: sym.name, kind: sym.symbolKind, symType: sym.symbolType,
			location: sym.location, prefixScore: 0, scopeDepth: 0, contextFit: false,
			isExported: hasFlag(sym, SF_EXPORTED), isMutable: hasFlag(sym, SF_MUTABLE),
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
	// Interface: interface Name
	if (suggest.kind === SymbolKind.Interface) {
		return "```ms\ninterface " + suggest.name + "\n```";
	}
	// Class: class Name
	if (suggest.kind === SymbolKind.Class) {
		return "```ms\nclass " + suggest.name + "\n```";
	}
	// Enum: enum Name
	if (suggest.kind === SymbolKind.Enum) {
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
export function sgFormatHoverDoc(suggest: SgSuggest): string {
	if (suggest === null) return "";
	let doc = "";
	if (suggest.isExported) doc = "*exported*";
	return doc;
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
		const diag: SgDiagnostic = {
			message: ctx.errors[i],
			line: 1,
			column: 0,
			severity: 1,
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
	if (receiverType !== null && receiverType.kind === TypeKind.Object) {
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
	// Extension methods
	if (receiverType !== null && ctx.extensionRegistry !== null) {
		const recTypeName = typeNameOf(receiverType);
		if (recTypeName.length > 0) {
			for (let j = 0; j < ctx.extensionRegistry.methods.length; j = j + 1) {
				const ext = ctx.extensionRegistry.methods[j];
				const ps = sgPrefixMatch(prefix, ext.methodName);
				if (ext.receiverTypeName === recTypeName && ps > 0) {
					const loc: SourceLocation = { line: 0, column: 0 };
					const item: SgSuggest = {
						name: ext.methodName, kind: SymbolKind.Method, symType: ext.fnType,
						location: loc, prefixScore: ps, scopeDepth: 0, contextFit: false,
					isExported: false, isMutable: false,
					};
					result.push(item);
				}
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
						isExported: hasFlag(sym, SF_EXPORTED), isMutable: hasFlag(sym, SF_MUTABLE),
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
		const item: SgDocumentSymbol = { name: fd.fnName, kind: SymbolKind.Function, location: node.location, detail: dt };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const vd = node.data as VariableDeclData;
		const dt = sgGetSymbolDetail(ctx, vd.declName);
		const item: SgDocumentSymbol = { name: vd.declName, kind: SymbolKind.Variable, location: node.location, detail: dt };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.InterfaceDecl) {
		const ifd = node.data as InterfaceDeclData;
		const dt = sgJoinFieldNames(ifd.interfaceFields);
		const item: SgDocumentSymbol = { name: ifd.interfaceName, kind: SymbolKind.Interface, location: node.location, detail: dt };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.EnumDecl) {
		const ed = node.data as EnumDeclData;
		const dt = sgJoinFieldNames(ed.enumMembers);
		const item: SgDocumentSymbol = { name: ed.enumName, kind: SymbolKind.Enum, location: node.location, detail: dt };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.ClassDecl) {
		const cd = node.data as ClassDeclData;
		const item: SgDocumentSymbol = { name: cd.className, kind: SymbolKind.Class, location: node.location, detail: cd.classExtends };
		result.push(item);
		return;
	}
	if (node.kind === NodeKind.TypeAliasDecl) {
		const td = node.data as TypeAliasDeclData;
		const dt = sgGetSymbolDetail(ctx, td.aliasName);
		const item: SgDocumentSymbol = { name: td.aliasName, kind: SymbolKind.TypeAlias, location: node.location, detail: dt };
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
		for (let j = 0; j < bd.statements.length; j = j + 1) {
			sgCollectHintsInNode(ctx, bd.statements[j], startLine, endLine, hints);
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
	if (node.kind === NodeKind.Program) {
		const pd = node.data as ProgramData;
		for (let i = 0; i < pd.programStmts.length; i = i + 1) {
			sgCollectRefsInNode(pd.programStmts[i], refs);
		}
		return;
	}

	if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		for (let i = 0; i < bd.statements.length; i = i + 1) {
			sgCollectRefsInNode(bd.statements[i], refs);
		}
		return;
	}

	if (node.kind === NodeKind.ExprStmt) {
		const es = node.data as ExprStmtData;
		sgCollectRefsInNode(es.expr, refs);
		return;
	}

	if (node.kind === NodeKind.ReturnStmt) {
		const rs = node.data as ReturnStmtData;
		if (rs.argument !== null) sgCollectRefsInNode(rs.argument, refs);
		return;
	}

	if (node.kind === NodeKind.BinaryExpr) {
		const be = node.data as BinaryExprData;
		sgCollectRefsInNode(be.left, refs);
		sgCollectRefsInNode(be.right, refs);
		return;
	}

	if (node.kind === NodeKind.UnaryExpr) {
		const ue = node.data as UnaryExprData;
		sgCollectRefsInNode(ue.operand, refs);
		return;
	}

	if (node.kind === NodeKind.CallExpr) {
		const ce = node.data as CallExprData;
		sgCollectRefsInNode(ce.callee, refs);
		for (let i = 0; i < ce.arguments.length; i = i + 1) {
			sgCollectRefsInNode(ce.arguments[i], refs);
		}
		return;
	}

	if (node.kind === NodeKind.MemberExpr) {
		const me = node.data as MemberExprData;
		sgCollectRefsInNode(me.object, refs);
		return;
	}

	if (node.kind === NodeKind.IfStmt) {
		const ifd = node.data as IfStmtData;
		sgCollectRefsInNode(ifd.condition, refs);
		sgCollectRefsInNode(ifd.consequent, refs);
		if (ifd.alternate !== null) sgCollectRefsInNode(ifd.alternate, refs);
		return;
	}

	if (node.kind === NodeKind.WhileStmt) {
		const ws = node.data as WhileStmtData;
		sgCollectRefsInNode(ws.whileCondition, refs);
		sgCollectRefsInNode(ws.whileBody, refs);
		return;
	}

	if (node.kind === NodeKind.ConditionalExpr) {
		const cnd = node.data as ConditionalExprData;
		sgCollectRefsInNode(cnd.ternaryCondition, refs);
		sgCollectRefsInNode(cnd.ternaryConsequent, refs);
		sgCollectRefsInNode(cnd.ternaryAlternate, refs);
		return;
	}

	if (node.kind === NodeKind.ExportDecl) {
		const ed = node.data as ExportDeclData;
		sgCollectRefsInNode(ed.exportedDecl, refs);
		return;
	}

	if (node.kind === NodeKind.ArrayLiteral) {
		const al = node.data as ArrayLiteralData;
		for (let i = 0; i < al.elements.length; i = i + 1) {
			sgCollectRefsInNode(al.elements[i], refs);
		}
		return;
	}
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
test "number" { check(sgTypeToString(numberType()) === "number"); }

test "string" { check(sgTypeToString(stringType()) === "string"); }

test "boolean" { check(sgTypeToString(booleanType()) === "boolean"); }

test "void" { check(sgTypeToString(voidType()) === "void"); }

test "null" { check(sgTypeToString(nullType()) === "null"); }

test "unknown" { check(sgTypeToString(unknownType()) === "unknown"); }

test "never" { check(sgTypeToString(neverType()) === "never"); }

test "error" { check(sgTypeToString(errorType()) === "error"); }

import { createArray, createFunction, createEnum, createObject, createResult } from "./types";
test "array" {
	const t = createArray(numberType());
	check(sgTypeToString(t) === "number[]");
}

test "function no params" {
	const params: Type[] = [];
	const names: string[] = [];
	const t = createFunction(params, names, voidType());
	check(sgTypeToString(t) === "() => void");
}

test "function with params" {
	const params: Type[] = [numberType(), stringType()];
	const names: string[] = ["a", "b"];
	const t = createFunction(params, names, booleanType());
	check(sgTypeToString(t) === "(a: number, b: string) => boolean");
}

test "enum" {
	const members: string[] = ["A", "B"];
	const t = createEnum("Color", members);
	check(sgTypeToString(t) === "Color");
}

test "named object" {
	const propNames: string[] = ["x", "y"];
	const propTypes: Type[] = [numberType(), numberType()];
	const t = createObject("Point", propNames, propTypes, true);
	check(sgTypeToString(t) === "Point");
}

test "result" {
	const t = createResult(numberType(), stringType());
	check(sgTypeToString(t) === "Result<number, string>");
}

test "find identifier in simple decl" {
	const pr = parseSource("const x = 42;");
	if (!pr.ok) { check(false); return; }
	// "const x" - x is at col 6
	const node = sgFindNodeAtPosition(pr.value, 1, 6);
	check(node !== null);
}

test "find in function body" {
	const pr = parseSource("function foo() { return 1; }");
	if (!pr.ok) { check(false); return; }
	const node = sgFindNodeAtPosition(pr.value, 1, 17);
	check(node !== null);
}

test "returns null for null node" {
	const nullNode = null as unknown as Node;
	const node = sgFindNodeAtPosition(nullNode, 1, 0);
	check(node === null);
}

test "returns null for unknown position" {
	const pr = parseSource("const x = 1;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const sg = sgGetSymbolAtCursor(ctx, pr.value, 100, 0);
	check(sg === null);
}

test "format variable hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "count", kind: SymbolKind.Variable, symType: numberType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	const hover = sgFormatHover(suggest);
	check(hover === "```ms\nconst count: number\n```");
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
	check(hover === "```ms\nfunction greet(s: string): void\n```");
}

test "format interface hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "Point", kind: SymbolKind.Interface, symType: unknownType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	check(sgFormatHover(suggest) === "```ms\ninterface Point\n```");
}

test "format class hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "Vec", kind: SymbolKind.Class, symType: unknownType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	check(sgFormatHover(suggest) === "```ms\nclass Vec\n```");
}

test "format enum hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "Color", kind: SymbolKind.Enum, symType: unknownType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	check(sgFormatHover(suggest) === "```ms\nenum Color\n```");
}

test "format type alias hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "Id", kind: SymbolKind.TypeAlias, symType: numberType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	check(sgFormatHover(suggest) === "```ms\ntype Id = number\n```");
}

test "format let variable hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "x", kind: SymbolKind.Variable, symType: stringType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: true,
	};
	check(sgFormatHover(suggest) === "```ms\nlet x: string\n```");
}

test "format parameter hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "name", kind: SymbolKind.Parameter, symType: stringType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	check(sgFormatHover(suggest) === "```ms\n(parameter) name: string\n```");
}

test "format property hover" {
	const loc: SourceLocation = { line: 1, column: 0 };
	const suggest: SgSuggest = {
		name: "x", kind: SymbolKind.Property, symType: numberType(),
		location: loc, prefixScore: 0, scopeDepth: 0, contextFit: false,
		isExported: false, isMutable: false,
	};
	check(sgFormatHover(suggest) === "```ms\n(property) x: number\n```");
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
	check(sgFormatHover(suggest) === "```ms\n(method) push(item: string): void\n```");
}

test "null suggest returns empty" {
	const sg = null as unknown as SgSuggest;
	check(sgFormatHover(sg) === "");
}

test "empty errors" {
	const pr = parseSource("const x = 1;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const diags = sgCollectDiagnostics(ctx);
	check(diags.length === 0);
}

test "dot triggers MemberAccess" {
	// "foo.b" — cursor at col 5 (after 'b')
	check(sgDetectCompletionContext("foo.b", 1, 5) === SgCompletionKind.MemberAccess);
}

test "dot with no prefix" {
	// "foo." — cursor at col 4 (right after '.')
	check(sgDetectCompletionContext("foo.", 1, 4) === SgCompletionKind.MemberAccess);
}

test "colon triggers TypeAnnotation" {
	// "x: num" — cursor at col 6
	check(sgDetectCompletionContext("x: num", 1, 6) === SgCompletionKind.TypeAnnotation);
}

test "bare identifier" {
	// "con" — cursor at col 3
	check(sgDetectCompletionContext("con", 1, 3) === SgCompletionKind.Identifier);
}

test "start of line" { check(sgDetectCompletionContext("x", 1, 0) === SgCompletionKind.Identifier); }

test "extracts prefix" { check(sgGetPrefix("foo.bar", 1, 7) === "bar"); }

test "no prefix after dot" { check(sgGetPrefix("foo.", 1, 4) === ""); }

test "whole word" { check(sgGetPrefix("hello", 1, 5) === "hello"); }

test "empty at start" { check(sgGetPrefix("x", 1, 0) === ""); }

test "prefix with underscore" { check(sgGetPrefix("my_var", 1, 6) === "my_var"); }

test "second line" { check(sgGetPrefix("abc\ndef", 2, 3) === "def"); }

test "finds top-level symbols" {
	const pr = parseSource("const abc = 1;\nconst abd = 2;\nconst xyz = 3;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "ab", null as unknown as Type);
	check(candidates.length === 2);
}

test "empty prefix returns all" {
	const pr = parseSource("const a = 1;\nconst b = 2;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "", null as unknown as Type);
	check(candidates.length >= 2);
}

test "no match returns empty" {
	const pr = parseSource("const abc = 1;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "zzz", null as unknown as Type);
	check(candidates.length === 0);
}

test "only returns types" {
	const pr = parseSource("interface Foo { x: number; }\nconst y = 1;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.TypeAnnotation, "", null as unknown as Type);
	// Should include Foo (interface) but not y (variable)
	let hasFoo = false;
	let hasY = false;
	for (let i = 0; i < candidates.length; i = i + 1) {
		if (candidates[i].name === "Foo") hasFoo = true;
		if (candidates[i].name === "y") hasY = true;
	}
	check(hasFoo);
	check(!hasY);
}

test "object properties" {
	const propNames: string[] = ["x", "y", "z"];
	const propTypes: Type[] = [numberType(), numberType(), stringType()];
	const objType = createObject("Point", propNames, propTypes, true);
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", objType);
	check(candidates.length === 3);
}

test "object properties with prefix" {
	const propNames: string[] = ["xPos", "yPos", "name"];
	const propTypes: Type[] = [numberType(), numberType(), stringType()];
	const objType = createObject("Obj", propNames, propTypes, true);
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "x", objType);
	check(candidates.length === 1);
	check(candidates[0].name === "xPos");
}

test "enum members" {
	const members: string[] = ["Red", "Green", "Blue"];
	const enumType = createEnum("Color", members);
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", enumType);
	check(candidates.length === 3);
}

test "null receiver returns empty" {
	const pr = parseSource("const a = 1;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.MemberAccess, "", null as unknown as Type);
	check(candidates.length === 0);
}

test "exact prefix" { check(sgPrefixMatch("ab", "abc") === 2); }

test "substring" { check(sgPrefixMatch("bc", "abcd") === 1); }

test "no match" { check(sgPrefixMatch("zz", "abc") === 0); }

test "case insensitive prefix" { check(sgPrefixMatch("AB", "abcde") === 2); }

test "empty prefix" { check(sgPrefixMatch("", "anything") === 2); }

test "prefix before substr" {
	const pr = parseSource("const abcdef = 1;\nconst xyzabc = 2;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "abc", null as unknown as Type);
	check(candidates.length === 2);
	// abcdef (prefix match) should come before xyzabc (substr match)
	check(candidates[0].name === "abcdef");
	check(candidates[1].name === "xyzabc");
}

test "inner scope before outer" {
	const pr = parseSource("const outer = 1;\nfunction f() { const inner = 2; }");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const candidates = sgGetCompletionCandidates(ctx, SgCompletionKind.Identifier, "", null as unknown as Type);
	// inner scope (depth 0) should rank before outer scope (depth > 0)
	// At least both should be present
	check(candidates.length >= 2);
	// First items should have lower scopeDepth
	if (candidates.length >= 2) {
		check(candidates[0].scopeDepth <= candidates[1].scopeDepth);
	}
}

test "collects function and variable" {
	const pr = parseSource("function foo() { return 1; }\nconst x = 1;");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	check(symbols.length === 2);
	check(symbols[0].name === "foo");
	check(symbols[0].kind === SymbolKind.Function);
	check(symbols[1].name === "x");
	check(symbols[1].kind === SymbolKind.Variable);
}

test "collects interface and enum" {
	const pr = parseSource("interface Point { x: number; }\nenum Color { Red, Green }");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	check(symbols.length === 2);
	check(symbols[0].name === "Point");
	check(symbols[0].kind === SymbolKind.Interface);
	check(symbols[1].name === "Color");
	check(symbols[1].kind === SymbolKind.Enum);
}

test "unwraps export decl" {
	const pr = parseSource("export function bar() { return 1; }");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	check(symbols.length === 1);
	check(symbols[0].name === "bar");
}

test "empty program" {
	const pr = parseSource("");
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const symbols = sgCollectSymbolsInFile(ctx, pr.value);
	check(symbols.length === 0);
}

test "function with params" {
	const params: Type[] = [numberType(), stringType()];
	const names: string[] = ["line", "msg"];
	const fnType = createFunction(params, names, voidType());
	const sym = makeSymbol("log", SymbolKind.Function, fnType, false);
	const sigs = sgFormatSignature(sym);
	check(sigs.length === 1);
	check(sigs[0].label === "log(line: number, msg: string): void");
	check(sigs[0].paramLabels.length === 2);
}

test "function no params" {
	const params: Type[] = [];
	const names: string[] = [];
	const fnType = createFunction(params, names, booleanType());
	const sym = makeSymbol("check", SymbolKind.Function, fnType, false);
	const sigs = sgFormatSignature(sym);
	check(sigs.length === 1);
	check(sigs[0].label === "check(): boolean");
	check(sigs[0].paramLabels.length === 0);
}

test "null symbol returns empty" {
	const nullSym = null as unknown as Symbol;
	const sigs = sgFormatSignature(nullSym);
	check(sigs.length === 0);
}

test "non-function symbol returns empty" {
	const sym = makeSymbol("x", SymbolKind.Variable, numberType(), false);
	const sigs = sgFormatSignature(sym);
	check(sigs.length === 0);
}

test "simple call" { check(sgGetCalleeAtCursor("foo(x", 1, 4) === "foo"); }

test "call with space before paren" { check(sgGetCalleeAtCursor("foo (x", 1, 5) === "foo"); }

test "nested call — inner" { check(sgGetCalleeAtCursor("foo(bar(x", 1, 8) === "bar"); }

test "not inside call returns empty" { check(sgGetCalleeAtCursor("hello", 1, 3) === ""); }

test "after comma" { check(sgGetCalleeAtCursor("add(1, 2", 1, 7) === "add"); }

test "first param" {
	// foo(| — cursor just after (
	check(sgCountActiveParam("foo(x", 1, 4) === 0);
}

test "second param" {
	// foo(a, | — cursor after comma
	check(sgCountActiveParam("foo(a, b", 1, 7) === 1);
}

test "third param" { check(sgCountActiveParam("foo(a, b, c", 1, 10) === 2); }

test "nested parens ignored" {
	// foo(bar(1, 2), | — inner commas don't count
	check(sgCountActiveParam("foo(bar(1, 2), x", 1, 15) === 1);
}

test "type hint for untyped variable" {
	const src = "const x = 42;";
	const pr = parseSource(src);
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	check(hints.length === 1);
	check(hints[0].label === ": number");
	check(hints[0].hintKind === SgInlayHintKind.Type);
}

test "no hint for explicitly typed variable" {
	const src = "const x: number = 42;";
	const pr = parseSource(src);
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	check(hints.length === 0);
}

test "parameter hints at call site" {
	const src = "function add(a: number, b: number): number { return a + b; }\nconst r = add(1, 2);";
	const pr = parseSource(src);
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	// Should have: type hint for r + param hints a: and b:
	let typeHints = 0;
	let paramHints = 0;
	for (let j = 0; j < hints.length; j = j + 1) {
		if (hints[j].hintKind === SgInlayHintKind.Type) { typeHints = typeHints + 1; }
		if (hints[j].hintKind === SgInlayHintKind.Parameter) { paramHints = paramHints + 1; }
	}
	check(typeHints >= 1);  // r: number
	check(paramHints === 2);  // a: 1, b: 2
}

test "skip param hint when arg matches param name" {
	const src = "function foo(x: number): void {}\nconst x = 5;\nfoo(x);";
	const pr = parseSource(src);
	if (!pr.ok) { check(false); return; }
	const ctx = checkProgram(pr.value);
	const hints = sgCollectInlayHints(ctx, pr.value, 1, 10);
	// x matches param name "x" — no param hint, just type hint for x
	let paramHints = 0;
	for (let j = 0; j < hints.length; j = j + 1) {
		if (hints[j].hintKind === SgInlayHintKind.Parameter) { paramHints = paramHints + 1; }
	}
	check(paramHints === 0);
}

test "collects declarations and usages" {
	const src = "const x = 1;\nconst y = x;";
	const pr = parseSource(src);
	if (!pr.ok) { check(false); return; }
	const refs = sgCollectReferences(pr.value);
	// x: 1 decl + 1 usage, y: 1 decl
	check(refs.length >= 3);
}

test "find usages by name" {
	const src = "const x = 1;\nconst y = x;";
	const pr = parseSource(src);
	if (!pr.ok) { check(false); return; }
	const refs = sgCollectReferences(pr.value);
	const xRefs = sgFindUsagesByName(refs, "x");
	check(xRefs.length === 2);
	// First should be decl, second should be usage
	check(xRefs[0].isDecl);
	check(!xRefs[1].isDecl);
}

test "function decl and call" {
	const src = "function greet(name: string): void {}\ngreet(\"hello\");";
	const pr = parseSource(src);
	if (!pr.ok) { check(false); return; }
	const refs = sgCollectReferences(pr.value);
	const greetRefs = sgFindUsagesByName(refs, "greet");
	check(greetRefs.length === 2);
	check(greetRefs[0].isDecl);
	check(!greetRefs[1].isDecl);
}

test "no references for unknown name" {
	const src = "const x = 1;";
	const pr = parseSource(src);
	if (!pr.ok) { check(false); return; }
	const refs = sgCollectReferences(pr.value);
	const noRefs = sgFindUsagesByName(refs, "nonexistent");
	check(noRefs.length === 0);
}
