// Declaration Parsers - variable, function, import, export, type alias, enum, interface
// Uses callback injection via util.ms to avoid circular imports

import { Token, TokenKind, isIdentOrKeyword } from "../../lexer/token";
import { Node, NodeKind, DeclKind, ExternKind, NodeData, SourceLocation, createNode, makeLoc, VariableDeclData, ExternDeclData, TypeAliasDeclData, MacroDeclData, FunctionDeclData, PropertyDeclData } from "../../ast/node";
import { ParserState, current, advance, isAtEnd, skipDestructurePattern, consumeSemicolon, skipGenericParams, captureGenericParams, skipBalanced, addGenericDecl, updateGenericDeclFields, collectTokenText } from "../context";
import { skipTypeAnnotation, parseTypeExpr } from "../typeAnnotation";
import { parseParamList, extractParamNames, extractParamTypes, captureOptionalType, getLastTypeExpr, skipDefaultValue, skipOptionalType, getLastParsedDefaults, getLastParamTypeExprs, getLastParamLocations, isIdentLike } from "../util";
import { callBlockParser, callExprParser } from "./callbacks";
import { sliceStr } from "../../utils/string";
import { programOk, stmtKind, stmtAt } from "./validation";


type NodeResult = Result<Node, string>;

function makeLocFromToken(token: Token): SourceLocation {
	return makeLoc(token.line, token.column);
}

// Shared specifier list parser for import/export: { name as alias, ... }
// Assumes opening '{' already consumed. Consumes up to but not including '}'.
interface SpecifierList { names: string[]; aliases: string[]; }

function parseSpecifierList(state: ParserState): SpecifierList {
	const names: string[] = [];
	const aliases: string[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		const specifier = current(state);
		if (!isIdentOrKeyword(specifier.kind)) { break; }
		const specName = specifier.value;
		advance(state);
		if (!isAtEnd(state) && current(state).kind === TokenKind.As) {
			advance(state);
			aliases.push(current(state).value);
			advance(state);
		} else {
			aliases.push(specName);
		}
		names.push(specName);
		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}
	return { names, aliases };
}

// ===== Variable Declaration =====
// syntax: ('const' | 'let') (ID | pattern) (':' type)? '=' expr ';'

export function parseVariableDecl(state: ParserState): NodeResult {
	const keyword = current(state);
	advance(state);

	// Destructuring: const { a, b } = ... or const [ x, y ] = ...
	if (current(state).kind === TokenKind.LBrace) {
		const pattern = try parseObjectPattern(state);
		skipOptionalType(state);
		if (current(state).kind !== TokenKind.Assign) {
			return Result.err(`Expected '=' after destructuring pattern at line ${current(state).line}`);
		}
		advance(state);
		const init = try callExprParser(state);
		consumeSemicolon(state);
		return Result.ok(createNode(NodeKind.DestructuringDecl, {
			destrPattern: pattern,
			destrInit: init,
			destrIsConst: keyword.kind === TokenKind.Const,
		}, keyword));
	}

	if (current(state).kind === TokenKind.LBracket) {
		const pattern = try parseArrayPattern(state);
		skipOptionalType(state);
		if (current(state).kind !== TokenKind.Assign) {
			return Result.err(`Expected '=' after destructuring pattern at line ${current(state).line}`);
		}
		advance(state);
		const init = try callExprParser(state);
		consumeSemicolon(state);
		return Result.ok(createNode(NodeKind.DestructuringDecl, {
			destrPattern: pattern,
			destrInit: init,
			destrIsConst: keyword.kind === TokenKind.Const,
		}, keyword));
	}

	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected identifier after ${keyword.value} at line ${nameToken.line}`);
	}

	advance(state);
	// Optional type annotation: const x: number = ...
	const declType = captureOptionalType(state);
	const declTypeExpr = getLastTypeExpr();

	if (current(state).kind !== TokenKind.Assign) {
		return Result.err(`Expected '=' in variable declaration at line ${current(state).line}`);
	}

	advance(state);
	const init = try callExprParser(state);
	consumeSemicolon(state);

	const varNode = createNode(NodeKind.VariableDecl, {
		declName: nameToken.value,
		declType,
		initializer: init,
		declKind: match (keyword.kind) { TokenKind.Const => DeclKind.Const, TokenKind.Var => DeclKind.Var, _ => DeclKind.Let },
		nameLocation: makeLocFromToken(nameToken),
	}, keyword);
	varNode.typeExpr = declTypeExpr;
	return Result.ok(varNode);
}

// ===== Specifier List Helper =====

// ===== Helpers =====

function stripFirstParam(arr: string[]): string[] {
	const result: string[] = [];
	for (let i = 1; i < arr.length; i += 1) { result.push(arr[i]); }
	return result;
}

// Detect extension method `this`/`typeof` in params and append to flags.
// Mutates params[0] for instance extensions (strips "this:" prefix).
// Appends generic names. Used by both regular and extern function parsers.
function applyExtensionFlags(flags: string, params: string[], fnParamTypes: string[], genericNames: string): string {
	// Instance extension: first param has "this:" prefix
	if (params.length > 0 && params[0].length > 5 && sliceStr(params[0], 0, 5) === "this:") {
		const receiverName = sliceStr(params[0], 5, params[0].length);
		const receiverType = fnParamTypes[0];
		if (flags === "") { flags = `ext:${receiverName}:${receiverType}`; }
		else { flags = `${flags}|ext:${receiverName}:${receiverType}`; }
		params[0] = receiverName;
	}
	// Static extension: first param has "typeof:" prefix
	if (params.length > 0 && params[0].length > 7 && sliceStr(params[0], 0, 7) === "typeof:") {
		const staticType = sliceStr(params[0], 7, params[0].length);
		if (flags === "") { flags = `sext:${staticType}`; }
		else { flags = `${flags}|sext:${staticType}`; }
	}
	// Out parameters: strip "out:" prefix, encode positions in flags
	let outPositions = "";
	for (let oi = 0; oi < params.length; oi += 1) {
		if (params[oi].length > 4 && sliceStr(params[oi], 0, 4) === "out:") {
			params[oi] = sliceStr(params[oi], 4, params[oi].length);
			if (outPositions === "") { outPositions = `${oi}`; }
			else { outPositions = `${outPositions},${oi}`; }
		}
	}
	if (outPositions !== "") {
		if (flags === "") { flags = `out:${outPositions}`; }
		else { flags = `${flags}|out:${outPositions}`; }
	}
	// Encode generic param names
	if (genericNames !== "") {
		if (flags === "") { flags = `gen:${genericNames}`; }
		else { flags = `${flags}|gen:${genericNames}`; }
	}
	return flags;
}

// ===== Function Declaration =====
// syntax: ('async')? 'function' ('*')? ID '(' params ')' (':' type)? block

export function parseFunctionDecl(state: ParserState): NodeResult {
	const fnToken = current(state);
	// Check for 'async' before 'function'
	let flags = "";
	if (current(state).kind === TokenKind.Async) {
		flags = "async";
		advance(state); // consume 'async'
	}
	advance(state); // consume 'function'
	// Check for generator: function* name()
	if (!isAtEnd(state) && current(state).kind === TokenKind.Star) {
		if (flags === "async") { flags = "async_generator"; }
		else { flags = "generator"; }
		advance(state); // consume '*'
	}
	const nameToken = current(state);
	// Accept Ident, OperatorIdent (backtick-quoted: `==`, `[]`), TemplateNoSub, or contextual keywords
	// Reference compiler: parser.zig:864 — operator_identifier token accepted as function name
	if (!isIdentLike(nameToken) && nameToken.kind !== TokenKind.TemplateNoSub && nameToken.kind !== TokenKind.OperatorIdent) {
		return Result.err(`Expected function name at line ${nameToken.line}`);
	}

	advance(state);
	// Capture optional generic params: function id<T>(x: T): T
	const genericNames = captureGenericParams(state);
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after function name at line ${current(state).line}`);
	}

	const raw = parseParamList(state, nameToken.value);
	const fnDefaults = getLastParsedDefaults();
	const fnParamTypeExprs = getLastParamTypeExprs();
	const fnParamLocs = getLastParamLocations();
	const params = extractParamNames(raw);
	const fnParamTypes = extractParamTypes(raw);

	// Detect extension methods and generics — single shared code path
	flags = applyExtensionFlags(flags, params, fnParamTypes, genericNames);

	// Static extensions strip the synthetic typeof param (not a runtime param)
	const isStatic = params.length > 0 && params[0].length > 7 && sliceStr(params[0], 0, 7) === "typeof:";

	// Optional return type annotation: function f(): string { ... }
	const fnReturnType = captureOptionalType(state);
	const fnReturnTypeExpr = getLastTypeExpr();

	const fnNode = createNode(NodeKind.FunctionDecl, {
		fnName: nameToken.value,
		params: isStatic ? stripFirstParam(params) : params,
		fnParamTypes: isStatic ? stripFirstParam(fnParamTypes) : fnParamTypes,
		fnBody: try callBlockParser(state),
		fnFlags: flags,
		fnReturnType,
		fnDefaults,
		nameLocation: makeLocFromToken(nameToken),
	}, fnToken);
	fnNode.typeExpr = fnReturnTypeExpr;
	fnNode.typeExprs = fnParamTypeExprs;
	fnNode.paramLocations = fnParamLocs;
	return Result.ok(fnNode);
}

// ===== Import Declaration =====
// syntax: 'import' '{' (ID ('as' ID)? ',')* '}' 'from' STRING ';'

export function parseImportDecl(state: ParserState): NodeResult {
	const importToken = current(state);
	advance(state);

	// Side-effect import: import "module";
	if (current(state).kind === TokenKind.String) {
		const source = current(state).value;
		advance(state);
		consumeSemicolon(state);
		return Result.ok(createNode(NodeKind.ImportDecl, {
			importNames: [],
			importAliases: [],
			importSource: source,
		}, importToken));
	}

	if (current(state).kind !== TokenKind.LBrace) {
		return Result.err(`Expected '{' or string after 'import' at line ${current(state).line}`);
	}

	advance(state);
	const specs = parseSpecifierList(state);
	const names = specs.names;
	const aliases = specs.aliases;

	if (current(state).kind !== TokenKind.RBrace) {
		return Result.err(`Expected '}' after import specifiers at line ${current(state).line}`);
	}

	advance(state);
	if (current(state).kind !== TokenKind.From) {
		return Result.err(`Expected 'from' after import specifiers at line ${current(state).line}`);
	}

	advance(state);
	if (current(state).kind !== TokenKind.String) {
		return Result.err(`Expected module path string at line ${current(state).line}`);
	}

	const source = current(state).value;
	advance(state);
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.ImportDecl, {
		importNames: names,
		importAliases: aliases,
		importSource: source,
	}, importToken));
}

// ===== Export Declaration =====
// syntax: 'export' (decl | '{' (ID ('as' ID)? ',')* '}' ('from' STRING)? ';')

export function parseExportDecl(state: ParserState): NodeResult {
	const exportToken = current(state);
	advance(state);

	// Each branch uses const + immediate return to avoid DRC try aliasing bug
	const nextKind = current(state).kind;
	// Re-export: export { X, Y } from "module";
	if (nextKind === TokenKind.LBrace) {
		advance(state); // skip '{'
		const specs = parseSpecifierList(state);
		const names = specs.names;
		const aliases = specs.aliases;
		if (current(state).kind === TokenKind.RBrace) { advance(state); }
		if (current(state).kind !== TokenKind.From) {
			return Result.err(`Expected 'from' after export specifiers at line ${current(state).line}`);
		}
		advance(state);
		if (current(state).kind !== TokenKind.String) {
			return Result.err(`Expected module path string at line ${current(state).line}`);
		}
		const source = current(state).value;
		advance(state);
		consumeSemicolon(state);
		const importNode = createNode(NodeKind.ImportDecl, {
			importNames: names, importAliases: aliases, importSource: source,
		}, exportToken);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: importNode }, exportToken));
	}

	if (nextKind === TokenKind.Function) {
		const decl = try parseFunctionDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind === TokenKind.Const || nextKind === TokenKind.Let) {
		const decl = try parseVariableDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind === TokenKind.Enum) {
		const decl = try parseEnumDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind === TokenKind.Interface) {
		const decl = try parseInterfaceDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind === TokenKind.Type) {
		const decl = try parseTypeAliasDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind === TokenKind.Class || nextKind === TokenKind.Abstract) {
		const decl = try parseClassDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	// export async function f() {}
	if (nextKind === TokenKind.Async) {
		const decl = try parseFunctionDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	// export extern function f(): void;
	if (nextKind === TokenKind.Extern) {
		const decl = try parseExternDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	// export default <expr>;
	if (nextKind === TokenKind.Default) {
		advance(state);
		// Check if default is followed by a declaration
		const afterDefault = current(state).kind;
		if (afterDefault === TokenKind.Function) {
			const decl = try parseFunctionDecl(state);
			return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
		}
		// Otherwise treat as expression
		const expr = try callExprParser(state);
		consumeSemicolon(state);
		const exprStmt = createNode(NodeKind.ExprStmt, { expr }, exportToken);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: exprStmt }, exportToken));
	}

	return Result.err(`Expected declaration after 'export' at line ${current(state).line}`);
}

// ===== Type Alias Declaration =====
// syntax: 'type' ID '=' type ';'

export function parseTypeAliasDecl(state: ParserState): NodeResult {
	const typeToken = current(state);

	advance(state);
	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected identifier after 'type' at line ${nameToken.line}`);
	}
	advance(state);
	if (current(state).kind !== TokenKind.Assign) {
		return Result.err(`Expected '=' in type alias at line ${current(state).line}`);
	}

	advance(state);

	// Discriminated union: type X = match (disc: EnumType) { EnumVal => { fields }, ... }
	if (current(state).kind === TokenKind.Match) {
		return parseDiscriminatedUnionDecl(state, nameToken.value, typeToken, nameToken);
	}

	const typeStart = state.position;
	skipTypeAnnotation(state);
	const typeEnd = state.position;
	const aliasType = collectTokenText(state, typeStart, typeEnd);
	// Build positioned TypeExpr by re-parsing the same range
	const savedPos = state.position;
	state.position = typeStart;
	const aliasTypeExpr = parseTypeExpr(state);
	state.position = savedPos;
	consumeSemicolon(state);

	const aliasNode = createNode(NodeKind.TypeAliasDecl, {
		aliasName: nameToken.value,
		aliasType,
		aliasIsDistinct: false,
		discriminantName: "",
		discriminantType: "",
		variantKeys: [] as string[],
		variantTypes: [] as string[],
		nameLocation: makeLocFromToken(nameToken),
	}, typeToken);
	aliasNode.typeExpr = aliasTypeExpr;
	return Result.ok(aliasNode);
}

// ===== Discriminated Union Declaration =====
// syntax: type X = match (discName: EnumType) { EnumVal => { fields }, ... };

function parseDiscriminatedUnionDecl(state: ParserState, aliasName: string, typeToken: Token, aliasNameToken: Token): NodeResult {
	advance(state); // consume 'match'

	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after 'match' in discriminated union at line ${current(state).line}`);
	}
	advance(state); // consume '('

	// Parse discriminant name
	const discNameToken = current(state);
	if (!isIdentLike(discNameToken)) {
		return Result.err(`Expected discriminant name in discriminated union at line ${current(state).line}`);
	}
	advance(state);

	if (current(state).kind !== TokenKind.Colon) {
		return Result.err(`Expected ':' after discriminant name at line ${current(state).line}`);
	}
	advance(state); // consume ':'

	// Parse discriminant type (e.g. NodeKind)
	const discTypeStart = state.position;
	skipTypeAnnotation(state);
	const discTypeEnd = state.position;
	const discriminantType = collectTokenText(state, discTypeStart, discTypeEnd);

	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after discriminant type at line ${current(state).line}`);
	}
	advance(state); // consume ')'

	if (current(state).kind !== TokenKind.LBrace) {
		return Result.err(`Expected '{' to start variant list at line ${current(state).line}`);
	}
	advance(state); // consume '{'

	const variantKeys: string[] = [];
	const variantTypes: string[] = [];

	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		// Parse variant key: EnumType.Member or just Member
		if (!isIdentLike(current(state))) {
			return Result.err(`Expected variant key at line ${current(state).line}`);
		}
		let key = current(state).value;
		advance(state); // consume first ident
		// Handle dotted names like NodeKind.NumLit
		while (!isAtEnd(state) && current(state).kind === TokenKind.Dot) {
			advance(state); // consume '.'
			key = `${key}.${current(state).value}`;
			advance(state); // consume member name
		}
		variantKeys.push(key);

		if (current(state).kind !== TokenKind.Arrow) {
			return Result.err(`Expected '=>' after variant key at line ${current(state).line}`);
		}
		advance(state); // consume '=>'

		// Parse variant type: { fields } or a type name
		const vtStart = state.position;
		skipTypeAnnotation(state);
		const vtEnd = state.position;
		const variantType = collectTokenText(state, vtStart, vtEnd);
		variantTypes.push(variantType);

		// Optional comma separator
		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		}
	}

	if (current(state).kind !== TokenKind.RBrace) {
		return Result.err(`Expected '}' to end variant list at line ${current(state).line}`);
	}
	advance(state); // consume '}'

	consumeSemicolon(state);

	// Build aliasType as regular union text for backward compatibility
	let aliasType = "";
	for (let i = 0; i < variantTypes.length; i += 1) {
		if (i > 0) {
			aliasType = `${aliasType} | ${variantTypes[i]}`;
		} else {
			aliasType = `| ${variantTypes[i]}`;
		}
	}

	return Result.ok(createNode(NodeKind.TypeAliasDecl, {
		aliasName,
		aliasType,
		aliasIsDistinct: false,
		discriminantName: discNameToken.value,
		discriminantType,
		variantKeys,
		variantTypes,
		nameLocation: makeLocFromToken(aliasNameToken),
	}, typeToken));
}

// ===== Enum Declaration =====
// syntax: 'enum' ID '{' (ID ('=' expr)? ',')* '}'

export function parseEnumDecl(state: ParserState): NodeResult {
	const enumToken = current(state);

	advance(state);
	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected identifier after 'enum' at line ${nameToken.line}`);
	}

	advance(state);
	if (current(state).kind !== TokenKind.LBrace) {
		return Result.err(`Expected '{' after enum name at line ${current(state).line}`);
	}

	advance(state);
	const members: string[] = [];
	const values: number[] = [];
	let nextValue: number = 0;
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		const member = current(state);
		if (!isIdentLike(member)) {
			return Result.err(`Expected enum member name at line ${member.line}`);
		}

		members.push(member.value);
		advance(state);
		// Optional value: A = 1 — parse number literal
		if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
			advance(state);
			const valTok = current(state);
			if (valTok.kind === TokenKind.Number) {
				nextValue = parseFloat(valTok.value);
				advance(state);
			} else {
				skipDefaultValue(state);
			}
		}
		values.push(nextValue);
		nextValue = nextValue + 1;

		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		}
	}

	if (current(state).kind !== TokenKind.RBrace) {
		return Result.err(`Expected '}' after enum members at line ${current(state).line}`);
	}

	advance(state);
	return Result.ok(createNode(NodeKind.EnumDecl, {
		enumName: nameToken.value,
		enumMembers: members,
		enumValues: values,
		nameLocation: makeLocFromToken(nameToken),
	}, enumToken));
}

// ===== Interface Declaration =====
// syntax: 'interface' ID ('<' params '>')? ('extends' type)? '{' members '}'

export function parseInterfaceDecl(state: ParserState): NodeResult {
	const ifaceToken = current(state);

	advance(state);
	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected identifier after 'interface' at line ${nameToken.line}`);
	}

	advance(state);
	// Optional generic type parameters: interface Box<T, U>
	let ifaceIsGeneric = false;
	if (!isAtEnd(state) && current(state).kind === TokenKind.Lt) {
		const genericNames = captureGenericParams(state);
		if (genericNames !== "") {
			addGenericDecl(nameToken.value, genericNames);
			ifaceIsGeneric = true;
		}
	}

	// Optional extends: interface X extends Y, Z { ... }
	if (!isAtEnd(state) && current(state).kind === TokenKind.Extends) {
		advance(state);
		// Skip extended type names (comma-separated identifiers)
		while (!isAtEnd(state) && current(state).kind !== TokenKind.LBrace) {
			advance(state);
		}
	}

	if (current(state).kind !== TokenKind.LBrace) {
		return Result.err(`Expected '{' after interface name at line ${current(state).line}`);
	}

	advance(state);
	const fields: string[] = [];
	const fieldTypes: string[] = [];
	const fieldTypeExprs: Node[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		const field = current(state);
		if (!isIdentLike(field)) {
			return Result.err(`Expected field name in interface at line ${field.line}`);
		}

		fields.push(field.value);
		advance(state);
		// Optional marker: field?: Type
		if (!isAtEnd(state) && current(state).kind === TokenKind.Question) {
			advance(state);
		}

		// Colon + type annotation — capture it
		fieldTypes.push(captureOptionalType(state));
		fieldTypeExprs.push(getLastTypeExpr());

		// Skip semicolons and commas between members
		if (!isAtEnd(state) && (current(state).kind === TokenKind.Semicolon || current(state).kind === TokenKind.Comma)) {
			advance(state);
		}
	}

	if (current(state).kind !== TokenKind.RBrace) {
		return Result.err(`Expected '}' after interface body at line ${current(state).line}`);
	}

	advance(state);

	// Store field info in generic decl side-channel for checker to use
	if (ifaceIsGeneric) {
		let fnJoined = "";
		let ftJoined = "";
		for (let fi = 0; fi < fields.length; fi += 1) {
			if (fi > 0) { fnJoined = `${fnJoined}|`; ftJoined = `${ftJoined}|`; }
			fnJoined = `${fnJoined}${fields[fi]}`;
			if (fi < fieldTypes.length) { ftJoined = `${ftJoined}${fieldTypes[fi]}`; }
		}
		updateGenericDeclFields(nameToken.value, fnJoined, ftJoined);
	}

	const ifaceNode = createNode(NodeKind.InterfaceDecl, {
		interfaceName: nameToken.value,
		interfaceFields: fields,
		interfaceFieldTypes: fieldTypes,
		nameLocation: makeLocFromToken(nameToken),
	}, ifaceToken);
	ifaceNode.typeExprs = fieldTypeExprs;
	return Result.ok(ifaceNode);
}

// ===== Class Declaration =====
// syntax: ('abstract')? 'class' ID ('<' params '>')? ('extends' type)? ('implements' type (',' type)*)? '{' members '}'

export function parseClassDecl(state: ParserState): NodeResult {
	const classToken = current(state);
	// Skip 'abstract' modifier if present
	if (current(state).kind === TokenKind.Abstract) {
		advance(state);
	}
	if (current(state).kind !== TokenKind.Class) {
		return Result.err(`Expected 'class' at line ${current(state).line}`);
	}
	advance(state);

	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected class name at line ${nameToken.line}`);
	}
	advance(state);

	// Optional generic type parameters: class Foo<T>
	let classIsGeneric = false;
	if (!isAtEnd(state) && current(state).kind === TokenKind.Lt) {
		const genericNames = captureGenericParams(state);
		if (genericNames !== "") {
			addGenericDecl(nameToken.value, genericNames);
			classIsGeneric = true;
		}
	}

	// Optional extends: class Foo extends Bar
	let extendsName = "";
	if (!isAtEnd(state) && current(state).kind === TokenKind.Extends) {
		advance(state);
		if (isIdentLike(current(state))) {
			extendsName = current(state).value;
			advance(state);
		}
		// Skip generic args on base class: extends Bar<T>
		skipGenericParams(state);
	}

	// Optional implements: class Foo implements Bar, Baz — skip
	if (!isAtEnd(state) && current(state).kind === TokenKind.Implements) {
		advance(state);
		while (!isAtEnd(state) && current(state).kind !== TokenKind.LBrace) {
			advance(state);
		}
	}

	if (current(state).kind !== TokenKind.LBrace) {
		return Result.err(`Expected '{' after class declaration at line ${current(state).line}`);
	}
	advance(state);

	const members: Node[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		if (current(state).kind === TokenKind.Semicolon) {
			advance(state);
			continue;
		}
		const member = try parseClassMember(state);
		members.push(member);
	}

	if (current(state).kind === TokenKind.RBrace) {
		advance(state);
	}

	// Store property info in generic decl side-channel for checker/codegen
	if (classIsGeneric) {
		let fnJoined = "";
		let ftJoined = "";
		for (const member of members) {
			if (member.kind === NodeKind.PropertyDecl) {
				const pd = member.data as PropertyDeclData;
				if (fnJoined !== "") { fnJoined = `${fnJoined}|`; ftJoined = `${ftJoined}|`; }
				fnJoined = `${fnJoined}${pd.propName}`;
				ftJoined = `${ftJoined}${pd.propType}`;
			}
		}
		updateGenericDeclFields(nameToken.value, fnJoined, ftJoined);
	}

	return Result.ok(createNode(NodeKind.ClassDecl, {
		className: nameToken.value,
		classExtends: extendsName,
		classBody: members,
		nameLocation: makeLocFromToken(nameToken),
	}, classToken));
}

function parseClassMember(state: ParserState): NodeResult {
	const memberToken = current(state);

	// Decorator before class member: @name(...) member
	if (current(state).kind === TokenKind.At) {
		const decorators: Node[] = [];
		while (!isAtEnd(state) && current(state).kind === TokenKind.At) {
			const dec = try parseMacroInvocation(state);
			decorators.push(dec);
		}
		const member = try parseClassMember(state);
		return Result.ok(createNode(NodeKind.DecoratedDecl, {
			decorators,
			decoratedNode: member,
		}, memberToken));
	}

	// Skip access modifiers: public, private, protected
	if (current(state).kind === TokenKind.Public ||
		current(state).kind === TokenKind.Private ||
		current(state).kind === TokenKind.Protected) {
		advance(state);
	}

	// Check for static
	let memberIsStatic = false;
	if (current(state).kind === TokenKind.Static) {
		memberIsStatic = true;
		advance(state);
	}

	// Check for readonly (skip as modifier)
	if (current(state).kind === TokenKind.Readonly) {
		advance(state);
	}

	// Check for abstract (skip as modifier)
	if (current(state).kind === TokenKind.Abstract) {
		advance(state);
	}

	// Check for extern modifier on methods
	let memberFlags = "";
	if (current(state).kind === TokenKind.Extern) {
		memberFlags = "extern";
		advance(state);
	}

	// Check for async modifier on methods
	if (current(state).kind === TokenKind.Async) {
		if (memberFlags !== "") { memberFlags = `${memberFlags}_async`; }
		else { memberFlags = "async"; }
		advance(state);
	}

	// Check for generator star on methods
	if (current(state).kind === TokenKind.Star) {
		if (memberFlags === "async") { memberFlags = "async_generator"; }
		else { memberFlags = "generator"; }
		advance(state);
	}

	// Constructor — early return, own scope for try
	if (current(state).kind === TokenKind.Constructor) {
		return parseClassConstructor(state);
	}

	// Get/Set accessors — early return
	if ((current(state).kind === TokenKind.Get || current(state).kind === TokenKind.Set) &&
		state.position + 1 < state.tokens.length &&
		isIdentLike(state.tokens[state.position + 1])) {
		return parseClassAccessor(state, memberIsStatic, memberFlags);
	}

	// Regular member: name followed by ( for method, or : / = / ; for property
	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected member name in class at line ${nameToken.line}`);
	}
	advance(state);

	// Optional question mark
	if (!isAtEnd(state) && current(state).kind === TokenKind.Question) {
		advance(state);
	}

	// Method — early return (LParen for regular, Lt for generic like parse<T>(...))
	if (!isAtEnd(state) && (current(state).kind === TokenKind.LParen || current(state).kind === TokenKind.Lt)) {
		return parseClassMethodBody(state, nameToken, memberIsStatic, memberFlags);
	}

	// Property — capture type, skip initializer tokens manually
	const propType = captureOptionalType(state);
	const propTypeExpr = getLastTypeExpr();
	if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
		advance(state);
		skipDefaultValue(state);
	}
	consumeSemicolon(state);

	const propNode = createNode(NodeKind.PropertyDecl, {
		propName: nameToken.value,
		propType,
		propIsStatic: memberIsStatic,
	}, nameToken);
	propNode.typeExpr = propTypeExpr;
	return Result.ok(propNode);
}

// parseParamList and skipDefaultValue imported from ../util


function parseClassConstructor(state: ParserState): NodeResult {
	const ctorToken = current(state);
	advance(state);
	const raw = parseParamList(state, "constructor");
	const ctorParamTypeExprs = getLastParamTypeExprs();
	const ctorParamLocs = getLastParamLocations();
	const ctorParams = extractParamNames(raw);
	const ctorParamTypes = extractParamTypes(raw);
	const body = try callBlockParser(state);
	const ctorNode = createNode(NodeKind.ConstructorDecl, {
		ctorParams,
		ctorParamTypes,
		ctorBody: body,
	}, ctorToken);
	ctorNode.typeExprs = ctorParamTypeExprs;
	ctorNode.paramLocations = ctorParamLocs;
	return Result.ok(ctorNode);
}

function parseClassAccessor(state: ParserState, isStatic: boolean, flags: string): NodeResult {
	const accToken = current(state);
	const accKind = current(state).value;
	advance(state);
	const accName = current(state).value;
	advance(state);
	const raw = parseParamList(state, `${accKind}_${accName}`);
	const accParamTypeExprs = getLastParamTypeExprs();
	const accParamLocs = getLastParamLocations();
	const methodParams = extractParamNames(raw);
	const methodParamTypes = extractParamTypes(raw);
	const methodReturnType = captureOptionalType(state);
	const methodReturnTypeExpr = getLastTypeExpr();
	const body = try callBlockParser(state);
	const accNode = createNode(NodeKind.MethodDecl, {
		methodName: `${accKind}_${accName}`,
		methodParams,
		methodParamTypes,
		methodBody: body,
		methodIsStatic: isStatic,
		nameLocation: makeLocFromToken(accToken),
		methodFlags: flags,
		methodReturnType,
	}, accToken);
	accNode.typeExpr = methodReturnTypeExpr;
	accNode.typeExprs = accParamTypeExprs;
	accNode.paramLocations = accParamLocs;
	return Result.ok(accNode);
}

function parseClassMethodBody(state: ParserState, nameToken: Token, isStatic: boolean, flags: string): NodeResult {
	// Capture optional generic params: method<T>(...) — same as regular function parser
	const genericNames = captureGenericParams(state);
	if (genericNames !== "") {
		if (flags === "") { flags = `gen:${genericNames}`; }
		else { flags = `${flags}|gen:${genericNames}`; }
	}
	const raw = parseParamList(state, nameToken.value);
	const methodParamTypeExprs = getLastParamTypeExprs();
	const methodParamLocs = getLastParamLocations();
	const methodParams = extractParamNames(raw);
	const methodParamTypes = extractParamTypes(raw);
	// Optional return type
	const methodReturnType = captureOptionalType(state);
	const methodRetTypeExpr = getLastTypeExpr();

	// Extern methods: 'from "c_name";' instead of body
	let methodNativeName = "";
	if (!isAtEnd(state) && current(state).kind === TokenKind.From) {
		advance(state); // consume 'from'
		if (!isAtEnd(state) && current(state).kind === TokenKind.String) {
			methodNativeName = current(state).value;
			advance(state);
		}
		consumeSemicolon(state);
		const mNode1 = createNode(NodeKind.MethodDecl, {
			methodName: nameToken.value,
			methodParams,
			methodParamTypes,
			methodBody: createNode(NodeKind.BlockStmt, { statements: [] }, nameToken),
			methodIsStatic: isStatic,
			methodFlags: flags,
			methodReturnType,
			nativeName: methodNativeName,
			nameLocation: makeLocFromToken(nameToken),
		}, nameToken);
		mNode1.typeExpr = methodRetTypeExpr;
		mNode1.typeExprs = methodParamTypeExprs;
		mNode1.paramLocations = methodParamLocs;
		return Result.ok(mNode1);
	}

	// Abstract methods / extern without 'from' — just semicolon
	if (current(state).kind === TokenKind.Semicolon) {
		consumeSemicolon(state);
		const mNode2 = createNode(NodeKind.MethodDecl, {
			methodName: nameToken.value,
			methodParams,
			methodParamTypes,
			methodBody: createNode(NodeKind.BlockStmt, { statements: [] }, nameToken),
			methodIsStatic: isStatic,
			methodFlags: flags,
			methodReturnType,
			nativeName: "",
			nameLocation: makeLocFromToken(nameToken),
		}, nameToken);
		mNode2.typeExpr = methodRetTypeExpr;
		mNode2.typeExprs = methodParamTypeExprs;
		mNode2.paramLocations = methodParamLocs;
		return Result.ok(mNode2);
	}
	const body = try callBlockParser(state);
	const mNode3 = createNode(NodeKind.MethodDecl, {
		methodName: nameToken.value,
		methodParams,
		methodParamTypes,
		methodBody: body,
		methodIsStatic: isStatic,
		methodFlags: flags,
		methodReturnType,
		nativeName: "",
		nameLocation: makeLocFromToken(nameToken),
	}, nameToken);
	mNode3.typeExpr = methodRetTypeExpr;
	mNode3.typeExprs = methodParamTypeExprs;
	mNode3.paramLocations = methodParamLocs;
	return Result.ok(mNode3);
}

// ===== Destructuring Patterns =====
// syntax: arrayPattern = '[' (ID | pattern | '...' ID)* ']'
// syntax: objectPattern = '{' (ID (':' (ID | pattern))? | '...' ID)* '}'

export function parseArrayPattern(state: ParserState): NodeResult {
	const bracketToken = current(state);
	advance(state); // consume '['
	const elements: Node[] = [];
	let hasRest = false;
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBracket) {
		// Rest element: ...x
		if (current(state).kind === TokenKind.DotDotDot) {
			hasRest = true;
			const spreadToken = current(state);
			advance(state);
			const restIdent = current(state);
			if (isIdentLike(restIdent)) {
				advance(state);
				elements.push(createNode(NodeKind.SpreadExpr, {
					spreadArg: createNode(NodeKind.Identifier, { name: restIdent.value }, restIdent),
				}, spreadToken));
			}
		} else if (current(state).kind === TokenKind.LBracket) {
			// Nested array pattern
			const nested = try parseArrayPattern(state);
			elements.push(nested);
		} else if (current(state).kind === TokenKind.LBrace) {
			// Nested object pattern
			const nested = try parseObjectPattern(state);
			elements.push(nested);
		} else if (isIdentLike(current(state))) {
			const elemToken = current(state);
			advance(state);
			elements.push(createNode(NodeKind.Identifier, { name: elemToken.value }, elemToken));
			// Skip default value: x = defaultVal
			if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
				advance(state);
				skipDefaultValue(state);
			}
		} else if (current(state).kind === TokenKind.Comma) {
			// Elision: [,, x] — push a placeholder
			elements.push(createNode(NodeKind.Identifier, { name: "_" }, current(state)));
		} else {
			break;
		}
		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}
	if (current(state).kind === TokenKind.RBracket) { advance(state); }
	return Result.ok(createNode(NodeKind.ArrayPattern, {
		patternElements: elements,
		hasRestElement: hasRest,
	}, bracketToken));
}

export function parseObjectPattern(state: ParserState): NodeResult {
	const braceToken = current(state);
	advance(state); // consume '{'
	const props: Node[] = [];
	let hasRest = false;
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		// Rest property: ...rest
		if (current(state).kind === TokenKind.DotDotDot) {
			hasRest = true;
			const spreadToken = current(state);
			advance(state);
			const restIdent = current(state);
			if (isIdentLike(restIdent)) {
				advance(state);
				props.push(createNode(NodeKind.SpreadExpr, {
					spreadArg: createNode(NodeKind.Identifier, { name: restIdent.value }, restIdent),
				}, spreadToken));
			}
		} else if (isIdentLike(current(state))) {
			const keyToken = current(state);
			advance(state);
			// Check for rename: { key: alias } or { key: { nested } } or { key: [nested] }
			if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
				advance(state); // consume ':'
				if (current(state).kind === TokenKind.LBrace) {
					const nested = try parseObjectPattern(state);
					props.push(createNode(NodeKind.ObjectPatternProp, {
						propKey: keyToken.value,
						propAlias: nested,
					}, keyToken));
				} else if (current(state).kind === TokenKind.LBracket) {
					const nested = try parseArrayPattern(state);
					props.push(createNode(NodeKind.ObjectPatternProp, {
						propKey: keyToken.value,
						propAlias: nested,
					}, keyToken));
				} else if (isIdentLike(current(state))) {
					const aliasToken = current(state);
					advance(state);
					props.push(createNode(NodeKind.ObjectPatternProp, {
						propKey: keyToken.value,
						propAlias: createNode(NodeKind.Identifier, { name: aliasToken.value }, aliasToken),
					}, keyToken));
					// Skip default value on alias
					if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
						advance(state);
						skipDefaultValue(state);
					}
				}
			} else {
				// Shorthand: { key } — alias is same as key
				props.push(createNode(NodeKind.ObjectPatternProp, {
					propKey: keyToken.value,
					propAlias: createNode(NodeKind.Identifier, { name: keyToken.value }, keyToken),
				}, keyToken));
				// Skip default value: { x = 5 }
				if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
					advance(state);
					skipDefaultValue(state);
				}
			}
		} else {
			break;
		}
		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}
	if (current(state).kind === TokenKind.RBrace) { advance(state); }
	return Result.ok(createNode(NodeKind.ObjectPattern, {
		patternProps: props,
		hasRestProp: hasRest,
	}, braceToken));
}

// skipDefaultValue imported from ../util

// ===== Macro Invocation (Decorator) =====
// syntax: '@' ID ('(' args ')')?

export function parseMacroInvocation(state: ParserState): NodeResult {
	const atToken = current(state);
	advance(state); // consume '@'
	const nameToken = current(state);
	// Accept identifiers and keywords as macro names (e.g., @export, @inline)
	const macroName = nameToken.value;
	advance(state);

	// @comptime { ... } — produce ComptimeBlock instead of MacroInvocation
	if (macroName === "comptime" && !isAtEnd(state) && current(state).kind === TokenKind.LBrace) {
		const comptimeBody = try callBlockParser(state);
		return Result.ok(createNode(NodeKind.ComptimeBlock, { comptimeBody }, atToken));
	}

	// Optional arguments: @name(arg1, arg2)
	const args: Node[] = [];
	if (!isAtEnd(state) && current(state).kind === TokenKind.LParen) {
		advance(state); // consume '('
		while (!isAtEnd(state) && current(state).kind !== TokenKind.RParen) {
			const arg = try callExprParser(state);
			args.push(arg);
			if (current(state).kind === TokenKind.Comma) {
				advance(state);
			} else {
				break;
			}
		}
		if (current(state).kind === TokenKind.RParen) {
			advance(state);
		}
	}

	return Result.ok(createNode(NodeKind.MacroInvocation, {
		macroName,
		macroArgs: args,
	}, atToken));
}

// ===== Extern Declaration =====
// syntax: 'extern' ('function' | 'class' | 'const' | 'var' | 'type' | 'enum' | 'interface' | 'macro') ID ...

export function parseExternDecl(state: ParserState): NodeResult {
	const externToken = current(state);
	advance(state); // consume 'extern'

	// Determine the extern kind from next keyword
	const kindToken = current(state);
	const externKind = match (kindToken.kind) {
		TokenKind.Function => ExternKind.Function,
		TokenKind.Class => ExternKind.Class,
		TokenKind.Const => ExternKind.Const,
		TokenKind.Var => ExternKind.Var,
		TokenKind.Let => ExternKind.Let,
		TokenKind.Type => ExternKind.Type,
		TokenKind.Enum => ExternKind.Enum,
		TokenKind.Interface => ExternKind.Interface,
		TokenKind.Macro => ExternKind.Macro,
		_ => ExternKind.Invalid,
	};
	if (externKind === ExternKind.Invalid) {
		return Result.err(`Expected declaration keyword after 'extern' at line ${kindToken.line}`);
	}
	advance(state); // consume the keyword

	// For macro: optional '@' prefix
	if (externKind === ExternKind.Macro && !isAtEnd(state) && current(state).kind === TokenKind.At) {
		advance(state);
	}

	// Parse name
	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected identifier in extern declaration at line ${nameToken.line}`);
	}
	advance(state);

	// Capture optional generic params: extern function sort<T>(arr: T[]): void
	const genericNames = captureGenericParams(state);

	// Extern functions → FunctionDecl with "extern" in fnFlags (Standard reference: importc pragma)
	if (externKind === ExternKind.Function) {
		const raw = parseParamList(state, nameToken.value);
		const externParamTypeExprs = getLastParamTypeExprs();
		const externParamLocs = getLastParamLocations();
		const params = extractParamNames(raw);
		const fnParamTypes = extractParamTypes(raw);

		// Detect extension methods (this/typeof) — same logic as regular functions
		let flags = applyExtensionFlags("extern", params, fnParamTypes, genericNames);

		const fnReturnType = captureOptionalType(state);
		const externRetTypeExpr = getLastTypeExpr();

		// Parse optional 'from "c_name"' clause or body/semicolon
		let nativeName = "";
		let fnBody: Node = createNode(NodeKind.BlockStmt, { statements: [] as Node[] }, externToken);
		if (!isAtEnd(state) && current(state).kind === TokenKind.From) {
			advance(state); // consume 'from'
			if (!isAtEnd(state) && current(state).kind === TokenKind.String) {
				nativeName = current(state).value;
				advance(state);
			}
			consumeSemicolon(state);
		} else if (!isAtEnd(state) && current(state).kind === TokenKind.LBrace) {
			fnBody = try callBlockParser(state);
		} else {
			consumeSemicolon(state);
		}

		// Static extensions strip the synthetic typeof param (not a runtime param)
		const isStatic = params.length > 0 && params[0].length > 7 && sliceStr(params[0], 0, 7) === "typeof:";

		const externFnNode = createNode(NodeKind.FunctionDecl, {
			fnName: nameToken.value,
			params: isStatic ? stripFirstParam(params) : params,
			fnParamTypes: isStatic ? stripFirstParam(fnParamTypes) : fnParamTypes,
			fnBody,
			fnFlags: flags,
			fnReturnType,
			fnDefaults: getLastParsedDefaults(),
			nativeName,
			nameLocation: makeLocFromToken(nameToken),
		}, externToken);
		externFnNode.typeExpr = externRetTypeExpr;
		externFnNode.typeExprs = externParamTypeExprs;
		externFnNode.paramLocations = externParamLocs;
		return Result.ok(externFnNode);
	}

	// Non-function externs: keep ExternDecl node
	skipBalanced(state, TokenKind.LParen, TokenKind.RParen);
	const externType = captureOptionalType(state);
	const externTypeExpr = getLastTypeExpr();

	// Skip optional 'extends' clause
	if (!isAtEnd(state) && current(state).kind === TokenKind.Extends) {
		advance(state);
		skipTypeAnnotation(state);
	}

	// Parse optional 'from "c_name"' clause or body/semicolon
	let externNativeName = "";
	if (!isAtEnd(state) && current(state).kind === TokenKind.From) {
		advance(state); // consume 'from'
		if (!isAtEnd(state) && current(state).kind === TokenKind.String) {
			externNativeName = current(state).value;
			advance(state);
		}
		consumeSemicolon(state);
	} else if (!isAtEnd(state) && current(state).kind === TokenKind.LBrace) {
		skipBalanced(state, TokenKind.LBrace, TokenKind.RBrace);
	} else {
		consumeSemicolon(state);
	}

	const externNode = createNode(NodeKind.ExternDecl, {
		externKind,
		externName: nameToken.value,
		nativeName: externNativeName,
		externType,
	}, externToken);
	externNode.typeExpr = externTypeExpr;
	return Result.ok(externNode);
}

// ===== Distinct Type Declaration =====
// syntax: 'distinct' 'type' ID '=' type ';'

export function parseDistinctTypeDecl(state: ParserState): NodeResult {
	const distinctToken = current(state);
	advance(state); // consume 'distinct'

	if (current(state).kind !== TokenKind.Type) {
		return Result.err(`Expected 'type' after 'distinct' at line ${current(state).line}`);
	}
	advance(state); // consume 'type'

	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected identifier after 'distinct type' at line ${nameToken.line}`);
	}
	advance(state);

	if (current(state).kind !== TokenKind.Assign) {
		return Result.err(`Expected '=' in distinct type declaration at line ${current(state).line}`);
	}
	advance(state);
	const dTypeStart = state.position;
	skipTypeAnnotation(state);
	const dTypeEnd = state.position;
	const distinctAliasType = collectTokenText(state, dTypeStart, dTypeEnd);
	// Build positioned TypeExpr by re-parsing
	const dSavedPos = state.position;
	state.position = dTypeStart;
	const distinctTypeExpr = parseTypeExpr(state);
	state.position = dSavedPos;
	consumeSemicolon(state);

	const distinctNode = createNode(NodeKind.TypeAliasDecl, {
		aliasName: nameToken.value,
		aliasType: distinctAliasType,
		aliasIsDistinct: true,
		discriminantName: "",
		discriminantType: "",
		variantKeys: [] as string[],
		variantTypes: [] as string[],
		nameLocation: makeLocFromToken(nameToken),
	}, distinctToken);
	distinctNode.typeExpr = distinctTypeExpr;
	return Result.ok(distinctNode);
}

// ===== Macro Declaration =====
// syntax: 'macro' ID '(' params ')' (':' type)? block

export function parseMacroDecl(state: ParserState): NodeResult {
	const macroToken = current(state);
	advance(state); // consume 'macro'

	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected identifier after 'macro' at line ${nameToken.line}`);
	}
	advance(state);

	const raw = parseParamList(state, nameToken.value);
	const macroDeclParams = extractParamNames(raw);

	// Optional return type
	skipOptionalType(state);

	const body = try callBlockParser(state);

	return Result.ok(createNode(NodeKind.MacroDecl, {
		macroDeclName: nameToken.value,
		macroDeclParams,
		macroDeclBody: body,
	}, macroToken));
}

// ===== Tests =====
// Variable — const vs let
test "const decl" { assert programOk("const x = 42;"); }

test "let decl" { assert programOk("let y = 0;"); }
// Function — empty, with params, with body
test "function empty" { assert programOk("function f() { }"); }

test "function multi-stmt" { assert programOk("function f() { const x = 1; return x; }"); }
// Import — distinct paths: named, aliased, side-effect
test "import named" { assert programOk("import { Token, TokenKind } from \"./token\";"); }

test "import aliased" { assert programOk("import { Token as T } from \"./token\";"); }

test "import side-effect" { assert programOk("import \"./polyfill\";"); }
// Export — distinct paths: decl, re-export, re-export aliased
test "export function" { assert programOk("export function f() { return 1; }"); }

test "export const" { assert programOk("export const x = 42;"); }

test "re-export" { assert programOk("export { Node, NodeKind } from \"./node\";"); }

test "re-export aliased" { assert programOk("export { Token as T } from \"./token\";"); }
// Type alias — distinct paths: simple, generic, union, function type
test "type simple" { assert programOk("type ID = number;"); }

test "type generic" { assert programOk("type NodeResult = Result<Node, string>;"); }

test "type leading pipe" { assert programOk("type Data = | { x: number } | { y: string };"); }

test "type function" { assert programOk("type Handler = (a: string) => void;"); }
// Enum
test "enum" { assert programOk("enum Color { Red, Green, Blue }"); }

test "enum with values" { assert programOk("enum Status { Active = 1, Inactive = 0 }"); }
// Interface — distinct paths: simple, optional, extends
test "interface" { assert programOk("interface Point { x: number; y: number; }"); }

test "interface optional" { assert programOk("interface Opt { value?: number; }"); }

test "interface extends" { assert programOk("interface Dog extends Animal { breed: string; }"); }
// Param features — exercises parseParamList + skipDefaultValue
test "rest param" { assert programOk("function f(...args) { return args; }"); }

test "default param" { assert programOk("function f(x = 5) { return x; }"); }

test "default param complex" { assert programOk("function f(x = [1, 2], y = {a: 3}) {}"); }

test "typed param" { assert programOk("function f(x: number, y: string) {}"); }
// Enum with complex values — exercises skipDefaultValue depth tracking
test "enum complex value" { assert programOk("enum E { A = fn(1, 2), B = arr[0] }"); }
// Var declarations
test "var decl" { assert programOk("var x = 1;"); }

test "var is VariableDecl" { assert stmtKind("var x = 1;") === NodeKind.VariableDecl; }

test "var declKind is Var" {
	const d = stmtAt("var x = 1;", 0).data as VariableDeclData;
	assert d.declKind === DeclKind.Var;
}

test "var declName" {
	const d = stmtAt("var x = 1;", 0).data as VariableDeclData;
	assert d.declName === "x";
}

test "var typed" { assert programOk("var x: number = 1;"); }
// Extern declarations — all 9 kinds
test "extern function" { assert programOk("extern function printf(fmt: string): void;"); }

test "extern class empty" { assert programOk("extern class FILE {}"); }

test "extern const" { assert programOk("extern const STDIN: FILE;"); }

test "extern enum" { assert programOk("extern enum Color { Red, Green }"); }

test "extern type" { assert programOk("extern type Ptr;"); }

test "extern var" { assert programOk("extern var errno: number;"); }

test "extern let" { assert programOk("extern let counter: number;"); }

test "extern interface" { assert programOk("extern interface Stream { read(): number; }"); }

test "extern macro" { assert programOk("extern macro @inject;"); }

test "extern function is FunctionDecl" { assert stmtKind("extern function f(): void;") === NodeKind.FunctionDecl; }

test "extern function has extern flag" {
	const d = stmtAt("extern function printf(fmt: string): void;", 0).data as FunctionDeclData;
	assert d.fnFlags === "extern";
}

test "extern const is ExternDecl" { assert stmtKind("extern const STDIN: int32;") === NodeKind.ExternDecl; }

test "extern name field" {
	const d = stmtAt("extern const STDIN: FILE;", 0).data as ExternDeclData;
	assert d.externName === "STDIN";
	assert d.externType === "FILE";
}

test "extern class kind" {
	const d = stmtAt("extern class FILE {}", 0).data as ExternDeclData;
	assert d.externKind === ExternKind.Class;
}

test "extern var with type and from" {
	const d = stmtAt("extern var errno: int32 from \"ms_errno\";", 0).data as ExternDeclData;
	assert d.externKind === ExternKind.Var;
	assert d.externName === "errno";
	assert d.externType === "int32";
	assert d.nativeName === "ms_errno";
}

test "extern const no from" {
	const d = stmtAt("extern const STDIN: FILE;", 0).data as ExternDeclData;
	assert d.externKind === ExternKind.Const;
	assert d.nativeName === "";
}

test "extern class opaque" {
	const d = stmtAt("extern class FILE;", 0).data as ExternDeclData;
	assert d.externKind === ExternKind.Class;
	assert d.externType === "";
}

test "extern generics" { assert programOk("extern function sort<T>(arr: T[]): void;"); }

test "extern extends" { assert programOk("extern class Derived extends Base {}"); }

test "extern error" { assert !programOk("extern 42"); }

test "export extern function" { assert programOk("export extern function foo(x: number): void;"); }

test "export extern function is ExportDecl" { assert stmtKind("export extern function foo(): void;") === NodeKind.ExportDecl; }

test "extern function from" { assert programOk("extern function floor(x: number): number from \"msFloor\";"); }

test "extern function from nativeName" {
	const d = stmtAt("extern function floor(x: number): number from \"msFloor\";", 0).data as FunctionDeclData;
	assert d.fnName === "floor";
	assert d.nativeName === "msFloor";
	assert d.fnFlags === "extern";
}

test "extern function without from" {
	const d = stmtAt("extern function printf(fmt: string): void;", 0).data as FunctionDeclData;
	assert d.fnName === "printf";
	assert d.nativeName === "";
}

// Distinct type
test "distinct type" { assert programOk("distinct type UserId = number;"); }

test "distinct type string" { assert programOk("distinct type Email = string;"); }

test "distinct is TypeAliasDecl" { assert stmtKind("distinct type X = number;") === NodeKind.TypeAliasDecl; }

test "distinct flag true" {
	const d = stmtAt("distinct type UserId = number;", 0).data as TypeAliasDeclData;
	assert d.aliasIsDistinct;
}

test "distinct name field" {
	const d = stmtAt("distinct type Email = string;", 0).data as TypeAliasDeclData;
	assert d.aliasName === "Email";
}

test "type alias not distinct" {
	const d = stmtAt("type ID = number;", 0).data as TypeAliasDeclData;
	assert !d.aliasIsDistinct;
}
// Macro declaration
test "macro decl" { assert programOk("macro deriveEq(target) { return target; }"); }

test "macro is MacroDecl" { assert stmtKind("macro foo(x) { return x; }") === NodeKind.MacroDecl; }

test "macro name field" {
	const d = stmtAt("macro deriveEq(target) { return target; }", 0).data as MacroDeclData;
	assert d.macroDeclName === "deriveEq";
}

test "macro multi param" { assert programOk("macro foo(a, b, c) { return a; }"); }

test "macro params field" {
	const d = stmtAt("macro foo(a, b, c) { return a; }", 0).data as MacroDeclData;
	assert d.macroDeclParams.length === 3;
}

test "macro body is block" {
	const d = stmtAt("macro foo(x) { return x; }", 0).data as MacroDeclData;
	assert d.macroDeclBody.kind === NodeKind.BlockStmt;
}

test "macro return type" { assert programOk("macro foo(): Node { return x; }"); }

test "macro empty params" { assert programOk("macro noop() { }"); }

test "async function" { assert programOk("async function f() {}"); }

test "generator function" { assert programOk("function* gen() { yield 1; }"); }

test "async generator" { assert programOk("async function* both() { yield 1; }"); }

test "export async" { assert programOk("export async function f() {}"); }

test "extension parses" { assert programOk("function f(this s: string) { return 1; }"); }

test "extension flags" {
	const n = stmtAt("function f(this s: string) { return 1; }", 0);
	const d = n.data as FunctionDeclData;
	assert d.fnFlags === "ext:s:string";
}

test "extension keeps receiver in params" {
	const n = stmtAt("function f(this s: string) { return 1; }", 0);
	const d = n.data as FunctionDeclData;
	assert d.params.length === 1;
	assert d.params[0] === "s";
}

test "extension with extra params" {
	const n = stmtAt("function f(this s: string, n: number) { return 1; }", 0);
	const d = n.data as FunctionDeclData;
	assert d.params.length === 2;
	assert d.params[0] === "s";
	assert d.params[1] === "n";
}

test "no receiver flags empty" {
	const n = stmtAt("function f(x: number) { return 1; }", 0);
	const d = n.data as FunctionDeclData;
	assert d.fnFlags === "";
}

test "object destructure" { assert stmtKind("const {a, b} = obj;") === NodeKind.DestructuringDecl; }

test "array destructure" { assert programOk("const [x, y] = arr;"); }

test "nested object" { assert programOk("const {a: {b, c}} = obj;"); }

test "object rest" { assert programOk("const {a, ...rest} = obj;"); }

test "array rest" { assert programOk("const [first, ...rest] = arr;"); }

test "let destructure" { assert programOk("let {x, y} = point;"); }

test "func destr param" { assert programOk("function f({x, y}) { return x; }"); }

test "func array param" { assert programOk("function f([a, b]) { return a; }"); }

test "arrow destr param" { assert programOk("const f = ({x}) => x;"); }
// Distinct member types
test "property" { assert programOk("class Foo { name: string; }"); }

test "method" { assert programOk("class Foo { greet() { return 1; } }"); }

test "constructor" { assert programOk("class Foo { constructor(x: number) { this.x = x; } }"); }
// Modifiers — each tests a distinct parser path
test "extends" { assert programOk("class Dog extends Animal { bark() { return 1; } }"); }

test "static" { assert programOk("class Foo { static create() { return 1; } }"); }

test "abstract" { assert programOk("abstract class Shape { abstract area(): number; }"); }

test "getter setter" { assert programOk("class Foo { get name() { return 1; } set name(v: string) { this.x = v; } }"); }

test "export class" { assert programOk("export class Foo { x: number; }"); }

test "async method" { assert programOk("class Foo { async fetch() {} }"); }

test "generator method" { assert programOk("class Foo { *items() { yield 1; } }"); }
// Complex
test "multi members" { assert programOk("class Point { x: number; y: number; toString() { return 1; } }"); }

test "constructor public" { assert programOk("class Foo { constructor(public name: string) { } }"); }
// Generic classes — exercises skipGenericParams in context.ms
test "generic class" { assert programOk("class Container<T> { value: T; }"); }

test "generic extends" { assert programOk("class List<T> extends Base<T> {}"); }

test "multi generic" { assert programOk("class Map<K, V> { lookup(k: K): V {} }"); }

test "implements" { assert programOk("class Foo implements Bar {}"); }
