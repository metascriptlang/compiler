// Declaration Parsers - variable, function, import, export, type alias, enum, interface
// Uses callback injection via util.ms to avoid circular imports

import { Token, TokenKind, isIdentOrKeyword } from "../../lexer/token";
import { Node, NodeKind, DeclKind, ExternKind, NodeFlag, SourceLocation, createNode, makeLoc, VariableDeclData, ExternDeclData, TypeAliasDeclData, MacroDeclData, FunctionDeclData, PropertyDeclData, ImportDeclData, ExportDeclData, DestructuringDeclData, ObjectPatternData, ObjectPatternPropData, ArrayPatternData } from "../../ast/node";
import { ParserState, current, advance, isAtEnd, peek, consumeSemicolon, skipGenericParams, captureGenericParams, skipBalanced, addGenericDecl, updateGenericDeclFields, collectTokenText } from "../context";
import { splitTopLevel, optionalizeTypeString } from "../../utils/string";
import { skipTypeAnnotation, parseTypeExpr } from "../typeAnnotation";
import { parseParamList, extractParamNames, extractParamTypes, captureOptionalType, getLastTypeExpr, skipDefaultValue, skipOptionalType, getLastParsedDefaults, getLastParamTypeExprs, getLastParamLocations, isIdentLike, isPropertyName } from "../util";
import { callBlockParser, callExprParser } from "./callbacks";
import { programOk, stmtKind, stmtAt } from "./validation";


type NodeResult = Result<Node, string>;

function makeLocFromToken(token: Token): SourceLocation {
	return makeLoc(token.line, token.column);
}

// Shared specifier list parser for import/export: { name as alias, ... }
// Assumes opening '{' already consumed. Consumes up to but not including '}'.
interface SpecifierList { names: string[]; aliases: string[]; locations: SourceLocation[]; }

function parseSpecifierList(state: ParserState): SpecifierList {
	const names: string[] = [];
	const aliases: string[] = [];
	const locations: SourceLocation[] = [];
	while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
		const specifier = current(state);
		if (!isIdentOrKeyword(specifier.kind)) { break; }
		const specName = specifier.value;
		locations.push(makeLoc(specifier.line, specifier.column));
		advance(state);
		if (!isAtEnd(state) && current(state).kind == TokenKind.As) {
			advance(state);
			aliases.push(current(state).value);
			advance(state);
		} else {
			aliases.push(specName);
		}
		names.push(specName);
		if (current(state).kind == TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}
	return { names, aliases, locations };
}

// ===== Variable Declaration =====
// syntax: ('const' | 'let') (ID | pattern) (':' type)? '=' expr ';'

// `static const/let/var x = …` inside a function or method body. The binding
// stays where it is written; only its storage moves to module scope, so a macro
// expanding at an expression position never has to reach the Program node.
export function parseStaticVariableDecl(state: ParserState): NodeResult {
	advance(state);
	const k = current(state).kind;
	if (k != TokenKind.Const && k != TokenKind.Let && k != TokenKind.Var) {
		return Result.err(`Expected 'const', 'let' or 'var' after 'static' at line ${current(state).line}`);
	}
	const decl = try parseVariableDecl(state);
	decl.flags = decl.flags | NodeFlag.StaticStorage;
	return Result.ok(decl);
}

export function parseVariableDecl(state: ParserState): NodeResult {
	const keyword = current(state);
	advance(state);

	// Destructuring: const { a, b } = ... or const [ x, y ] = ...
	if (current(state).kind == TokenKind.LBrace) {
		const pattern = try parseObjectPattern(state);
		skipOptionalType(state);
		if (current(state).kind != TokenKind.Assign) {
			return Result.err(`Expected '=' after destructuring pattern at line ${current(state).line}`);
		}
		advance(state);
		const init = try callExprParser(state);
		consumeSemicolon(state);
		return Result.ok(createNode(NodeKind.DestructuringDecl, {
			destrPattern: pattern,
			destrInit: init,
			destrIsConst: keyword.kind == TokenKind.Const,
		}, keyword));
	}

	if (current(state).kind == TokenKind.LBracket) {
		const pattern = try parseArrayPattern(state);
		skipOptionalType(state);
		if (current(state).kind != TokenKind.Assign) {
			return Result.err(`Expected '=' after destructuring pattern at line ${current(state).line}`);
		}
		advance(state);
		const init = try callExprParser(state);
		consumeSemicolon(state);
		return Result.ok(createNode(NodeKind.DestructuringDecl, {
			destrPattern: pattern,
			destrInit: init,
			destrIsConst: keyword.kind == TokenKind.Const,
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

	// Uninitialized declaration: `let x: Type;` — requires type annotation, disallowed for const
	let init: Node | null = null;
	if (current(state).kind == TokenKind.Assign) {
		advance(state);
		init = try callExprParser(state);
	} else if (declType == "") {
		return Result.err(`Expected '=' or type annotation in declaration at line ${current(state).line}`);
	} else if (keyword.kind == TokenKind.Const) {
		return Result.err(`'const' declaration must be initialized at line ${current(state).line}`);
	}
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

function stripFirstDefault(arr: Node[]): Node[] {
	const result: Node[] = [];
	for (let i = 1; i < arr.length; i += 1) { result.push(arr[i]); }
	return result;
}

// Detect extension method `this`/`typeof` in params and append to flags.
// Mutates params[0] for instance extensions (strips "this:" prefix).
// Appends generic names. Used by both regular and extern function parsers.
function applyExtensionFlags(flags: string, params: string[], fnParamTypes: string[], genericNames: string): string {
	// Instance extension: first param has "this:" prefix
	if (params.length > 0 && params[0].length > 5 && params[0].slice(0, 5) == "this:") {
		const receiverName = params[0].slice(5, params[0].length);
		const receiverType = fnParamTypes[0];
		if (flags == "") { flags = `ext:${receiverName}:${receiverType}`; }
		else { flags = `${flags}|ext:${receiverName}:${receiverType}`; }
		params[0] = receiverName;
	}
	// Static extension: first param has "typeof:" prefix
	if (params.length > 0 && params[0].length > 7 && params[0].slice(0, 7) == "typeof:") {
		const staticType = params[0].slice(7, params[0].length);
		if (flags == "") { flags = `sext:${staticType}`; }
		else { flags = `${flags}|sext:${staticType}`; }
	}
	// Out/ref/readonly parameters: strip prefix, encode positions in flags
	let outPositions = "";
	let refPositions = "";
	let rdonlyPositions = "";
	for (let oi = 0; oi < params.length; oi += 1) {
		if (params[oi].length > 4 && params[oi].slice(0, 4) == "out:") {
			params[oi] = params[oi].slice(4, params[oi].length);
			if (outPositions == "") { outPositions = `${oi}`; }
			else { outPositions = `${outPositions},${oi}`; }
		}
		if (params[oi].length > 4 && params[oi].slice(0, 4) == "ref:") {
			params[oi] = params[oi].slice(4, params[oi].length);
			if (refPositions == "") { refPositions = `${oi}`; }
			else { refPositions = `${refPositions},${oi}`; }
		}
		if (params[oi].length > 7 && params[oi].slice(0, 7) == "rdonly:") {
			params[oi] = params[oi].slice(7, params[oi].length);
			if (rdonlyPositions == "") { rdonlyPositions = `${oi}`; }
			else { rdonlyPositions = `${rdonlyPositions},${oi}`; }
		}
	}
	if (outPositions != "") {
		if (flags == "") { flags = `out:${outPositions}`; }
		else { flags = `${flags}|out:${outPositions}`; }
	}
	if (refPositions != "") {
		if (flags == "") { flags = `ref:${refPositions}`; }
		else { flags = `${flags}|ref:${refPositions}`; }
	}
	if (rdonlyPositions != "") {
		if (flags == "") { flags = `rdonly:${rdonlyPositions}`; }
		else { flags = `${flags}|rdonly:${rdonlyPositions}`; }
	}
	// Encode generic param names
	if (genericNames != "") {
		if (flags == "") { flags = `gen:${genericNames}`; }
		else { flags = `${flags}|gen:${genericNames}`; }
	}
	return flags;
}

// ===== Function Declaration =====
// syntax: ('async')? 'function' ('*')? ID '(' params ')' (':' type)? block

export function parseFunctionDecl(state: ParserState): NodeResult {
	const fnToken = current(state);
	let flags = "";
	if (current(state).kind == TokenKind.Async) {
		flags = "async";
		advance(state); // consume 'async'
	}
	advance(state); // consume 'function'
	// Check for generator: function* name()
	if (!isAtEnd(state) && current(state).kind == TokenKind.Star) {
		if (flags == "async") { flags = "async_generator"; }
		else { flags = "generator"; }
		advance(state); // consume '*'
	}
	const nameToken = current(state);
	// Accept Ident, OperatorIdent (backtick-quoted: `==`, `[]`), TemplateNoSub, or contextual keywords
	if (!isIdentLike(nameToken) && !isPropertyName(nameToken) && nameToken.kind != TokenKind.TemplateNoSub && nameToken.kind != TokenKind.OperatorIdent) {
		return Result.err(`Expected function name at line ${nameToken.line}`);
	}

	advance(state);
	// Capture optional generic params: function id<T>(x: T): T
	const genericNames = captureGenericParams(state);
	if (current(state).kind != TokenKind.LParen) {
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
	const isStatic = params.length > 0 && params[0].length > 7 && params[0].slice(0, 7) == "typeof:";

	// Optional return type annotation: function f(): string { ... }
	const fnReturnType = captureOptionalType(state);
	const fnReturnTypeExpr = getLastTypeExpr();

	// Overload signature (TypeScript parity): body-less declaration terminated by semicolon.
	//   function f(k: K.A): void;
	//   function f(k: K.B): void;
	//   function f(k: K): void { ... }   // implementation comes last
	let fnBody: Node;
	let fnFlagsFinal: string;
	if (!isAtEnd(state) && current(state).kind == TokenKind.Semicolon) {
		advance(state); // consume ;
		fnBody = createNode(NodeKind.BlockStmt, { statements: [] }, fnToken);
		fnFlagsFinal = flags == "" ? "overload" : (flags + " overload");
	} else {
		fnBody = try callBlockParser(state);
		fnFlagsFinal = flags;
	}

	const fnNode = createNode(NodeKind.FunctionDecl, {
		fnName: nameToken.value,
		params: isStatic ? stripFirstParam(params) : params,
		fnParamTypes: isStatic ? stripFirstParam(fnParamTypes) : fnParamTypes,
		fnBody,
		fnFlags: fnFlagsFinal,
		fnReturnType,
		fnDefaults: isStatic ? stripFirstDefault(fnDefaults) : fnDefaults,
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
	if (current(state).kind == TokenKind.String) {
		const source = current(state).value;
		advance(state);
		consumeSemicolon(state);
		return Result.ok(createNode(NodeKind.ImportDecl, {
			importNames: [],
			importAliases: [],
			importSource: source,
			nameLocations: [],
		}, importToken));
	}

	// Namespace import: import * as ns from "module";
	if (current(state).kind == TokenKind.Star) {
		advance(state); // skip *
		if (current(state).kind != TokenKind.As) {
			return Result.err(`Expected 'as' after 'import *' at line ${current(state).line}`);
		}
		advance(state); // skip 'as'
		if (current(state).kind != TokenKind.Ident) {
			return Result.err(`Expected namespace name after 'import * as' at line ${current(state).line}`);
		}
		const nsName = current(state).value;
		advance(state);
		if (current(state).kind != TokenKind.From) {
			return Result.err(`Expected 'from' after 'import * as ${nsName}' at line ${current(state).line}`);
		}
		advance(state);
		if (current(state).kind != TokenKind.String) {
			return Result.err(`Expected module path string at line ${current(state).line}`);
		}
		const source = current(state).value;
		advance(state);
		consumeSemicolon(state);
		return Result.ok(createNode(NodeKind.ImportDecl, {
			importNames: ["*"], importAliases: [nsName], importSource: source, nameLocations: [],
		}, importToken));
	}

	if (current(state).kind != TokenKind.LBrace) {
		return Result.err(`Expected '{' or string after 'import' at line ${current(state).line}`);
	}

	advance(state);
	const specs = parseSpecifierList(state);
	const names = specs.names;
	const aliases = specs.aliases;

	if (current(state).kind != TokenKind.RBrace) {
		return Result.err(`Expected '}' after import specifiers at line ${current(state).line}`);
	}

	advance(state);
	if (current(state).kind != TokenKind.From) {
		return Result.err(`Expected 'from' after import specifiers at line ${current(state).line}`);
	}

	advance(state);
	if (current(state).kind != TokenKind.String) {
		return Result.err(`Expected module path string at line ${current(state).line}`);
	}

	const source = current(state).value;
	advance(state);
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.ImportDecl, {
		importNames: names,
		importAliases: aliases,
		importSource: source,
		nameLocations: specs.locations,
	}, importToken));
}

// ===== Export Declaration =====
// syntax: 'export' (decl | '{' (ID ('as' ID)? ',')* '}' ('from' STRING)? ';')

export function parseExportDecl(state: ParserState): NodeResult {
	const exportToken = current(state);
	advance(state);

	// Each branch uses const + immediate return to avoid DRC try aliasing bug
	const nextKind = current(state).kind;
	// Star re-export: export * from "module";
	if (nextKind == TokenKind.Star) {
		advance(state); // skip *
		if (current(state).kind != TokenKind.From) {
			return Result.err(`Expected 'from' after 'export *' at line ${current(state).line}`);
		}
		advance(state);
		if (current(state).kind != TokenKind.String) {
			return Result.err(`Expected module path string at line ${current(state).line}`);
		}
		const source = current(state).value;
		advance(state);
		consumeSemicolon(state);
		const importNode = createNode(NodeKind.ImportDecl, {
			importNames: ["*"], importAliases: ["*"], importSource: source, nameLocations: [],
		}, exportToken);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: importNode }, exportToken));
	}
	// Re-export: export { X, Y } from "module";
	if (nextKind == TokenKind.LBrace) {
		advance(state); // skip '{'
		const specs = parseSpecifierList(state);
		const names = specs.names;
		const aliases = specs.aliases;
		if (current(state).kind == TokenKind.RBrace) { advance(state); }
		if (current(state).kind != TokenKind.From) {
			return Result.err(`Expected 'from' after export specifiers at line ${current(state).line}`);
		}
		advance(state);
		if (current(state).kind != TokenKind.String) {
			return Result.err(`Expected module path string at line ${current(state).line}`);
		}
		const source = current(state).value;
		advance(state);
		consumeSemicolon(state);
		const importNode = createNode(NodeKind.ImportDecl, {
			importNames: names, importAliases: aliases, importSource: source, nameLocations: specs.locations,
		}, exportToken);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: importNode }, exportToken));
	}

	if (nextKind == TokenKind.Function) {
		const decl = try parseFunctionDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind == TokenKind.Const || nextKind == TokenKind.Let) {
		const decl = try parseVariableDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind == TokenKind.Enum) {
		const decl = try parseEnumDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind == TokenKind.Interface) {
		const decl = try parseInterfaceDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind == TokenKind.Struct) {
		const decl = try parseStructDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind == TokenKind.Type) {
		const decl = try parseTypeAliasDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind == TokenKind.Distinct) {
		const decl = try parseDistinctTypeDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind == TokenKind.Class || nextKind == TokenKind.Abstract) {
		const decl = try parseClassDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind == TokenKind.Actor) {
		const decl = try parseActorDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind == TokenKind.Macro) {
		const decl = try parseMacroDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind == TokenKind.Converter) {
		const decl = try parseConverterDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	if (nextKind == TokenKind.Template) {
		// parseFunctionDecl consumes the keyword token — 'template' acts like 'function'
		const decl = try parseFunctionDecl(state);
		const fd = decl.data as FunctionDeclData;
		fd.fnFlags = fd.fnFlags == "" ? "template" : fd.fnFlags + "|template";
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	// export async function f() {}
	if (nextKind == TokenKind.Async) {
		const decl = try parseFunctionDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	// export extern function f(): void;
	if (nextKind == TokenKind.Extern) {
		const decl = try parseExternDecl(state);
		return Result.ok(createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken));
	}

	// export default <expr>;
	if (nextKind == TokenKind.Default) {
		advance(state);
		// Check if default is followed by a declaration
		const afterDefault = current(state).kind;
		if (afterDefault == TokenKind.Function) {
			const decl = try parseFunctionDecl(state);
			const exportNode = createNode(NodeKind.ExportDecl, { exportedDecl: decl }, exportToken);
			exportNode.flags = exportNode.flags | NodeFlag.ExportDefault;
			return Result.ok(exportNode);
		}
		// Otherwise treat as expression
		const expr = try callExprParser(state);
		consumeSemicolon(state);
		const exprStmt = createNode(NodeKind.ExprStmt, { expr }, exportToken);
		const exportNode = createNode(NodeKind.ExportDecl, { exportedDecl: exprStmt }, exportToken);
		exportNode.flags = exportNode.flags | NodeFlag.ExportDefault;
		return Result.ok(exportNode);
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

	// Tier 3: capture optional generic params: type Box<T> = ...
	const genericNames = captureGenericParams(state);
	if (genericNames != "") {
		addGenericDecl(nameToken.value, genericNames);
	}

	if (current(state).kind != TokenKind.Assign) {
		return Result.err(`Expected '=' in type alias at line ${current(state).line}`);
	}

	advance(state);

	// Discriminated union: type X = match (disc: EnumOrBool) { Key => { fields }, ... }
	if (current(state).kind == TokenKind.Match) {
		return parseDiscriminatedUnionDecl(state, nameToken.value, genericNames, typeToken, nameToken);
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
		aliasGenericParams: genericNames,
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
// syntax: type X = match (discName: EnumOrBool) { Key => { fields }, ... };
//   - Enum discriminator: keys are enum members (`MyKind.Ok`, `MyKind.Err`)
//   - Boolean discriminator: keys are `true` / `false` literals

function parseDiscriminatedUnionDecl(state: ParserState, aliasName: string, genericNames: string, typeToken: Token, aliasNameToken: Token): NodeResult {
	advance(state); // consume 'match'

	if (current(state).kind != TokenKind.LParen) {
		return Result.err(`Expected '(' after 'match' in discriminated union at line ${current(state).line}`);
	}
	advance(state); // consume '('

	const discNameToken = current(state);
	if (!isIdentLike(discNameToken)) {
		return Result.err(`Expected discriminant name in discriminated union at line ${current(state).line}`);
	}
	advance(state);

	if (current(state).kind != TokenKind.Colon) {
		return Result.err(`Expected ':' after discriminant name at line ${current(state).line}`);
	}
	advance(state); // consume ':'

	// Parse discriminant type (e.g. NodeKind)
	const discTypeStart = state.position;
	skipTypeAnnotation(state);
	const discTypeEnd = state.position;
	const discriminantType = collectTokenText(state, discTypeStart, discTypeEnd);

	if (current(state).kind != TokenKind.RParen) {
		return Result.err(`Expected ')' after discriminant type at line ${current(state).line}`);
	}
	advance(state); // consume ')'

	if (current(state).kind != TokenKind.LBrace) {
		return Result.err(`Expected '{' to start variant list at line ${current(state).line}`);
	}
	advance(state); // consume '{'

	const variantKeys: string[] = [];
	const variantTypes: string[] = [];

	while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
		// Parse variant key: EnumType.Member, just Member, or boolean literal (true/false)
		// Boolean literals are accepted for match-type unions over `boolean` discriminants.
		const tok = current(state);
		const isBoolLit = tok.kind == TokenKind.True || tok.kind == TokenKind.False;
		if (!isBoolLit && !isIdentLike(tok)) {
			return Result.err(`Expected variant key at line ${tok.line}`);
		}
		let key = isBoolLit ? (tok.kind == TokenKind.True ? "true" : "false") : tok.value;
		advance(state); // consume first ident
		// Handle dotted names like NodeKind.NumLit
		while (!isAtEnd(state) && current(state).kind == TokenKind.Dot) {
			advance(state); // consume '.'
			key = `${key}.${current(state).value}`;
			advance(state); // consume member name
		}
		variantKeys.push(key);

		if (current(state).kind != TokenKind.Arrow) {
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
		if (current(state).kind == TokenKind.Comma) {
			advance(state);
		}
	}

	if (current(state).kind != TokenKind.RBrace) {
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
		aliasGenericParams: genericNames,
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
	if (current(state).kind != TokenKind.LBrace) {
		return Result.err(`Expected '{' after enum name at line ${current(state).line}`);
	}

	advance(state);
	const members: string[] = [];
	const memberLocs: SourceLocation[] = [];
	const values: number[] = [];
	let nextValue: number = 0;
	while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
		const member = current(state);
		if (!isPropertyName(member)) {
			return Result.err(`Expected enum member name at line ${member.line}`);
		}

		members.push(member.value);
		memberLocs.push(makeLocFromToken(member));
		advance(state);
		// Optional value: A = 1 — parse number literal
		if (!isAtEnd(state) && current(state).kind == TokenKind.Assign) {
			advance(state);
			const valTok = current(state);
			if (valTok.kind == TokenKind.Number) {
				nextValue = parseFloat(valTok.value);
				advance(state);
			} else {
				skipDefaultValue(state);
			}
		}
		values.push(nextValue);
		nextValue = nextValue + 1;

		if (current(state).kind == TokenKind.Comma) {
			advance(state);
		}
	}

	if (current(state).kind != TokenKind.RBrace) {
		return Result.err(`Expected '}' after enum members at line ${current(state).line}`);
	}

	advance(state);
	return Result.ok(createNode(NodeKind.EnumDecl, {
		enumName: nameToken.value,
		enumMembers: members,
		enumValues: values,
		nameLocation: makeLocFromToken(nameToken),
		memberLocations: memberLocs,
	}, enumToken));
}

// ===== Interface Declaration =====
// syntax: 'interface' ID ('<' params '>')? ('extends' type)? '{' members '}'

// Parse interface body: { field: Type; ... } — shared by parseInterfaceDecl and extern interface.
function parseInterfaceBody(state: ParserState, name: string, token: Token, genericNames: string, nodeKind: NodeKind, nameLoc: SourceLocation = null as unknown as SourceLocation): NodeResult {
	const keyword = nodeKind == NodeKind.StructDecl ? "struct" : "interface";
	let ifaceIsGeneric = genericNames != "";
	if (ifaceIsGeneric) {
		addGenericDecl(name, genericNames);
	}

	// Optional extends: interface X extends Y, Z { ... }
	// Capture each parent type expression (e.g. "Y", "Container<int>", "A<T>")
	// as a raw string. Comma-separated at top level; `<>` nesting tracked.
	const extendsList: string[] = [];
	if (!isAtEnd(state) && current(state).kind == TokenKind.Extends) {
		advance(state);
		while (!isAtEnd(state) && current(state).kind != TokenKind.LBrace) {
			const parentStart = state.position;
			let depth = 0;
			while (!isAtEnd(state)) {
				const tk = current(state).kind;
				if (depth == 0 && (tk == TokenKind.Comma || tk == TokenKind.LBrace)) break;
				if (tk == TokenKind.Lt) depth = depth + 1;
				else if (tk == TokenKind.Gt) depth = depth - 1;
				advance(state);
			}
			const parentExpr = collectTokenText(state, parentStart, state.position).trim();
			if (parentExpr != "") extendsList.push(parentExpr);
			if (!isAtEnd(state) && current(state).kind == TokenKind.Comma) advance(state);
		}
	}

	if (current(state).kind != TokenKind.LBrace) {
		return Result.err(`Expected '{' after ${keyword} name at line ${current(state).line}`);
	}

	advance(state);
	const fields: string[] = [];
	const fieldTypes: string[] = [];
	const fieldTypeExprs: Node[] = [];
	const fieldLocations: SourceLocation[] = [];
	while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
		const field = current(state);
		if (!isPropertyName(field)) {
			return Result.err(`Expected field name in ${keyword} at line ${field.line}`);
		}

		fields.push(field.value);
		fieldLocations.push(makeLocFromToken(field));
		advance(state);
		let fieldIsOptional = false;
		if (!isAtEnd(state) && current(state).kind == TokenKind.Question) {
			if (nodeKind == NodeKind.StructDecl) {
				return Result.err(`Optional field '${field.value}?' in struct at line ${field.line}: '?' means '| null' and a struct field is a value type — write the nullable union type explicitly`);
			}
			fieldIsOptional = true;
			advance(state);
		}

		const fieldTypeStr = captureOptionalType(state);
		fieldTypes.push(fieldIsOptional ? optionalizeTypeString(fieldTypeStr) : fieldTypeStr);
		fieldTypeExprs.push(getLastTypeExpr());

		if (!isAtEnd(state) && (current(state).kind == TokenKind.Semicolon || current(state).kind == TokenKind.Comma)) {
			advance(state);
		}
	}

	if (current(state).kind != TokenKind.RBrace) {
		return Result.err(`Expected '}' after ${keyword} body at line ${current(state).line}`);
	}

	advance(state);

	if (ifaceIsGeneric) {
		let fnJoined = "";
		let ftJoined = "";
		for (let fi = 0; fi < fields.length; fi += 1) {
			if (fi > 0) { fnJoined = `${fnJoined}|`; ftJoined = `${ftJoined}|`; }
			fnJoined = `${fnJoined}${fields[fi]}`;
			if (fi < fieldTypes.length) { ftJoined = `${ftJoined}${fieldTypes[fi]}`; }
		}
		updateGenericDeclFields(name, fnJoined, ftJoined);
	}

	const ifaceNode = createNode(nodeKind, {
		interfaceName: name,
		interfaceFields: fields,
		interfaceFieldTypes: fieldTypes,
		interfaceExtends: extendsList,
		// nameLoc (from nameToken) is preferred; fall back to keyword token for legacy callers.
		nameLocation: nameLoc != null ? nameLoc : makeLocFromToken(token),
	}, token);
	ifaceNode.typeExprs = fieldTypeExprs;
	// Repurpose paramLocations for per-field name source locations (used by resolvePass
	// to emit correct symRecords for LSP documentHighlight/goto-def).
	ifaceNode.paramLocations = fieldLocations;
	return Result.ok(ifaceNode);
}

function parseStructLikeDecl(state: ParserState, keyword: string, nodeKind: NodeKind): NodeResult {
	const token = current(state);
	advance(state);
	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected identifier after '${keyword}' at line ${nameToken.line}`);
	}
	const nameLoc = makeLocFromToken(nameToken);
	advance(state);

	let genericNames = "";
	if (!isAtEnd(state) && current(state).kind == TokenKind.Lt) {
		genericNames = captureGenericParams(state);
	}

	// Alias form: `struct X = TypeExpr;` or `struct X = A & B;` — composes
	// fields from the RHS type expressions. Body is implicit empty; parent
	// list captured into interfaceExtends. See LANG.md §4.6.
	// Brace depth tracked so anonymous object operands `{ role: string; }` —
	// which contain semicolons — don't terminate the RHS prematurely.
	if (!isAtEnd(state) && current(state).kind == TokenKind.Assign) {
		advance(state);
		const rhsStart = state.position;
		let braceDepth = 0;
		while (!isAtEnd(state)) {
			const tk = current(state).kind;
			if (tk == TokenKind.LBrace) braceDepth = braceDepth + 1;
			else if (tk == TokenKind.RBrace) braceDepth = braceDepth - 1;
			else if (tk == TokenKind.Semicolon && braceDepth == 0) break;
			advance(state);
		}
		const rhsExpr = collectTokenText(state, rhsStart, state.position).trim();
		if (!isAtEnd(state) && current(state).kind == TokenKind.Semicolon) advance(state);
		const parts = splitTopLevel(rhsExpr, "&");
		const aliasExtends: string[] = [];
		for (const p of parts) {
			const tp = p.trim();
			if (tp != "") aliasExtends.push(tp);
		}
		if (genericNames != "") addGenericDecl(nameToken.value, genericNames);
		const aliasNode = createNode(nodeKind, {
			interfaceName: nameToken.value,
			interfaceFields: [],
			interfaceFieldTypes: [],
			interfaceExtends: aliasExtends,
			nameLocation: nameLoc,
		}, token);
		aliasNode.typeExprs = [];
		aliasNode.paramLocations = [];
		return Result.ok(aliasNode);
	}

	return parseInterfaceBody(state, nameToken.value, token, genericNames, nodeKind, nameLoc);
}

export function parseInterfaceDecl(state: ParserState): NodeResult {
	return parseStructLikeDecl(state, "interface", NodeKind.InterfaceDecl);
}

export function parseStructDecl(state: ParserState): NodeResult {
	return parseStructLikeDecl(state, "struct", NodeKind.StructDecl);
}

// ===== Class Declaration =====
// syntax: ('abstract')? 'class' ID ('<' params '>')? ('extends' type)? ('implements' type (',' type)*)? '{' members '}'

export function parseClassDecl(state: ParserState): NodeResult {
	const classToken = current(state);
	// Skip 'abstract' modifier if present
	if (current(state).kind == TokenKind.Abstract) {
		advance(state);
	}
	if (current(state).kind != TokenKind.Class) {
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
	if (!isAtEnd(state) && current(state).kind == TokenKind.Lt) {
		const genericNames = captureGenericParams(state);
		if (genericNames != "") {
			addGenericDecl(nameToken.value, genericNames);
			classIsGeneric = true;
		}
	}

	// Optional extends: class Foo extends Bar / class Foo extends Bar<T>
	let extendsName = "";
	if (!isAtEnd(state) && current(state).kind == TokenKind.Extends) {
		advance(state);
		const extStart = state.position;
		if (isIdentLike(current(state))) {
			advance(state);
			// Capture generic args via depth-tracked skip — preserved in extendsName.
			if (!isAtEnd(state) && current(state).kind == TokenKind.Lt) {
				let depth = 1;
				advance(state);
				while (!isAtEnd(state) && depth > 0) {
					const tk = current(state).kind;
					if (tk == TokenKind.Lt) depth = depth + 1;
					else if (tk == TokenKind.Gt) depth = depth - 1;
					advance(state);
				}
			}
			extendsName = collectTokenText(state, extStart, state.position).trim();
		}
	}

	// Optional implements: class Foo implements Bar, Baz — skip
	if (!isAtEnd(state) && current(state).kind == TokenKind.Implements) {
		advance(state);
		while (!isAtEnd(state) && current(state).kind != TokenKind.LBrace) {
			advance(state);
		}
	}

	if (current(state).kind != TokenKind.LBrace) {
		return Result.err(`Expected '{' after class declaration at line ${current(state).line}`);
	}
	advance(state);

	const members: Node[] = [];
	while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
		if (current(state).kind == TokenKind.Semicolon) {
			advance(state);
			continue;
		}
		const member = try parseClassMember(state);
		members.push(member);
	}

	if (current(state).kind == TokenKind.RBrace) {
		advance(state);
	}

	// Store property info in generic decl side-channel for checker/codegen
	if (classIsGeneric) {
		let fnJoined = "";
		let ftJoined = "";
		for (const member of members) {
			if (member.kind == NodeKind.PropertyDecl) {
				const pd = member.data as PropertyDeclData;
				if (fnJoined != "") { fnJoined = `${fnJoined}|`; ftJoined = `${ftJoined}|`; }
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

// ===== Actor Declaration =====
// syntax: 'actor' ID ('<' params '>')? '{' members '}'

export function parseActorDecl(state: ParserState): NodeResult {
	const actorToken = current(state);
	if (current(state).kind != TokenKind.Actor) {
		return Result.err(`Expected 'actor' at line ${current(state).line}`);
	}
	advance(state);

	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected actor name at line ${nameToken.line}`);
	}
	advance(state);

	// Optional generic type parameters: actor Foo<T>
	if (!isAtEnd(state) && current(state).kind == TokenKind.Lt) {
		const genericNames = captureGenericParams(state);
		if (genericNames != "") {
			addGenericDecl(nameToken.value, genericNames);
		}
	}

	if (current(state).kind != TokenKind.LBrace) {
		return Result.err(`Expected '{' after actor declaration at line ${current(state).line}`);
	}
	advance(state);

	const members: Node[] = [];
	while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
		if (current(state).kind == TokenKind.Semicolon) {
			advance(state);
			continue;
		}
		const member = try parseClassMember(state);
		members.push(member);
	}

	if (current(state).kind == TokenKind.RBrace) {
		advance(state);
	}

	return Result.ok(createNode(NodeKind.ActorDecl, {
		actorName: nameToken.value,
		actorBody: members,
		nameLocation: makeLocFromToken(nameToken),
	}, actorToken));
}

function parseClassMember(state: ParserState): NodeResult {
	const memberToken = current(state);

	// Decorator before class member: @name(...) member
	if (current(state).kind == TokenKind.At) {
		const decorators: Node[] = [];
		while (!isAtEnd(state) && current(state).kind == TokenKind.At) {
			const dec = try parseMacroInvocation(state);
			decorators.push(dec);
		}
		const member = try parseClassMember(state);
		return Result.ok(createNode(NodeKind.DecoratedDecl, {
			decorators,
			decoratedNode: member,
		}, memberToken));
	}

	// Capture access modifiers: public, private, protected
	let memberVisibility = "";
	if (current(state).kind == TokenKind.Public) {
		memberVisibility = "public";
		advance(state);
	} else if (current(state).kind == TokenKind.Private) {
		memberVisibility = "private";
		advance(state);
	} else if (current(state).kind == TokenKind.Protected) {
		memberVisibility = "protected";
		advance(state);
	}

	// Check for static
	let memberIsStatic = false;
	if (current(state).kind == TokenKind.Static) {
		memberIsStatic = true;
		advance(state);
	}

	// Check for readonly
	let memberIsReadonly = false;
	if (current(state).kind == TokenKind.Readonly) {
		memberIsReadonly = true;
		advance(state);
	}

	// Check for abstract (skip as modifier)
	if (current(state).kind == TokenKind.Abstract) {
		advance(state);
	}

	// Check for extern modifier on methods
	let memberFlags = "";
	if (current(state).kind == TokenKind.Extern) {
		memberFlags = "extern";
		advance(state);
	}

	// Check for async modifier on methods
	if (current(state).kind == TokenKind.Async) {
		if (memberFlags != "") { memberFlags = `${memberFlags}_async`; }
		else { memberFlags = "async"; }
		advance(state);
	}

	// Check for generator star on methods
	if (current(state).kind == TokenKind.Star) {
		if (memberFlags == "async") { memberFlags = "async_generator"; }
		else { memberFlags = "generator"; }
		advance(state);
	}

	// Constructor — early return, own scope for try
	if (current(state).kind == TokenKind.Constructor) {
		return parseClassConstructor(state);
	}

	// Get/Set accessors — early return
	// Lookahead must use peek() to skip comments, not raw state.tokens[pos+1]
	if ((current(state).kind == TokenKind.Get || current(state).kind == TokenKind.Set) &&
		isIdentLike(peek(state, 1))) {
		return parseClassAccessor(state, memberIsStatic, memberFlags, memberVisibility);
	}

	// Regular member: name followed by ( for method, or : / = / ; for property
	const nameToken = current(state);
	if (!isPropertyName(nameToken)) {
		return Result.err(`Expected member name in class at line ${nameToken.line}`);
	}
	advance(state);

	let memberIsOptional = false;
	if (!isAtEnd(state) && current(state).kind == TokenKind.Question) {
		memberIsOptional = true;
		advance(state);
	}

	// Method — early return (LParen for regular, Lt for generic like parse<T>(...))
	if (!isAtEnd(state) && (current(state).kind == TokenKind.LParen || current(state).kind == TokenKind.Lt)) {
		if (memberIsOptional) {
			return Result.err(`Optional method '${nameToken.value}?' at line ${nameToken.line}: declare a property with a nullable function type instead`);
		}
		return parseClassMethodBody(state, nameToken, memberIsStatic, memberFlags, memberVisibility);
	}

	// Property — capture type and optional initializer
	const propTypeRaw = captureOptionalType(state);
	const propType = memberIsOptional ? optionalizeTypeString(propTypeRaw) : propTypeRaw;
	const propTypeExpr = getLastTypeExpr();
	let propInit: Node = null as unknown as Node;
	if (!isAtEnd(state) && current(state).kind == TokenKind.Assign) {
		advance(state);
		propInit = try callExprParser(state);
	}
	consumeSemicolon(state);

	const propNode = createNode(NodeKind.PropertyDecl, {
		propName: nameToken.value,
		propType,
		propIsStatic: memberIsStatic,
		propIsReadonly: memberIsReadonly,
		propVisibility: memberVisibility,
		propInitializer: propInit,
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
	const ctorDefaults = getLastParsedDefaults();
	const ctorParams = extractParamNames(raw);
	const ctorParamTypes = extractParamTypes(raw);
	const body = try callBlockParser(state);
	const ctorNode = createNode(NodeKind.ConstructorDecl, {
		ctorParams,
		ctorParamTypes,
		ctorBody: body,
		ctorDefaults,
	}, ctorToken);
	ctorNode.typeExprs = ctorParamTypeExprs;
	ctorNode.paramLocations = ctorParamLocs;
	return Result.ok(ctorNode);
}

function parseClassAccessor(state: ParserState, isStatic: boolean, flags: string, visibility: string): NodeResult {
	const accToken = current(state);
	const accKind = current(state).value;
	advance(state);
	const accNameToken = current(state);
	const accName = accNameToken.value;
	advance(state);
	const raw = parseParamList(state, `${accKind}_${accName}`);
	const accParamTypeExprs = getLastParamTypeExprs();
	const accParamLocs = getLastParamLocations();
	const accDefaults = getLastParsedDefaults();
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
		nameLocation: makeLocFromToken(accNameToken),
		methodFlags: flags,
		methodVisibility: visibility,
		methodReturnType,
		methodDefaults: accDefaults,
		nativeName: "",
	}, accToken);
	accNode.typeExpr = methodReturnTypeExpr;
	accNode.typeExprs = accParamTypeExprs;
	accNode.paramLocations = accParamLocs;
	return Result.ok(accNode);
}

function parseClassMethodBody(state: ParserState, nameToken: Token, isStatic: boolean, flags: string, visibility: string): NodeResult {
	// Capture optional generic params: method<T>(...) — same as regular function parser
	const genericNames = captureGenericParams(state);
	if (genericNames != "") {
		if (flags == "") { flags = `gen:${genericNames}`; }
		else { flags = `${flags}|gen:${genericNames}`; }
	}
	const raw = parseParamList(state, nameToken.value);
	const methodParamTypeExprs = getLastParamTypeExprs();
	const methodParamLocs = getLastParamLocations();
	const methodDefaults = getLastParsedDefaults();
	const methodParams = extractParamNames(raw);
	const methodParamTypes = extractParamTypes(raw);
	// Optional return type
	const methodReturnType = captureOptionalType(state);
	const methodRetTypeExpr = getLastTypeExpr();

	// Extern methods: 'from "c_name";' instead of body
	let methodNativeName = "";
	if (!isAtEnd(state) && current(state).kind == TokenKind.From) {
		advance(state); // consume 'from'
		if (!isAtEnd(state) && current(state).kind == TokenKind.String) {
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
			methodVisibility: visibility,
			methodReturnType,
			methodDefaults,
			nativeName: methodNativeName,
			nameLocation: makeLocFromToken(nameToken),
		}, nameToken);
		mNode1.typeExpr = methodRetTypeExpr;
		mNode1.typeExprs = methodParamTypeExprs;
		mNode1.paramLocations = methodParamLocs;
		return Result.ok(mNode1);
	}

	// Abstract methods / extern without 'from' — just semicolon
	if (current(state).kind == TokenKind.Semicolon) {
		consumeSemicolon(state);
		const mNode2 = createNode(NodeKind.MethodDecl, {
			methodName: nameToken.value,
			methodParams,
			methodParamTypes,
			methodBody: createNode(NodeKind.BlockStmt, { statements: [] }, nameToken),
			methodIsStatic: isStatic,
			methodFlags: flags,
			methodVisibility: visibility,
			methodReturnType,
			methodDefaults,
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
		methodVisibility: visibility,
		methodReturnType,
		methodDefaults,
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
	const defaults: Node[] = [];
	let hasRest = false;
	while (!isAtEnd(state) && current(state).kind != TokenKind.RBracket) {
		// Rest element: ...x
		if (current(state).kind == TokenKind.DotDotDot) {
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
		} else if (current(state).kind == TokenKind.LBracket) {
			// Nested array pattern
			const nested = try parseArrayPattern(state);
			elements.push(nested);
		} else if (current(state).kind == TokenKind.LBrace) {
			// Nested object pattern
			const nested = try parseObjectPattern(state);
			elements.push(nested);
		} else if (isIdentLike(current(state))) {
			const elemToken = current(state);
			advance(state);
			elements.push(createNode(NodeKind.Identifier, { name: elemToken.value }, elemToken));
			if (!isAtEnd(state) && current(state).kind == TokenKind.Assign) {
				advance(state);
				const dIdx = elements.length - 1;
				while (defaults.length < dIdx) { defaults.push(null); }
				const dExpr = try callExprParser(state);
				defaults.push(dExpr);
			}
		} else if (current(state).kind == TokenKind.Comma) {
			// Elision: [,, x] — push a placeholder
			elements.push(createNode(NodeKind.Identifier, { name: "_" }, current(state)));
		} else {
			break;
		}
		if (current(state).kind == TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}
	if (current(state).kind == TokenKind.RBracket) { advance(state); }
	return Result.ok(createNode(NodeKind.ArrayPattern, {
		patternElements: elements,
		hasRestElement: hasRest,
		patternDefaults: defaults,
	}, bracketToken));
}

export function parseObjectPattern(state: ParserState): NodeResult {
	const braceToken = current(state);
	advance(state); // consume '{'
	const props: Node[] = [];
	let hasRest = false;
	while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
		// Rest property: ...rest
		if (current(state).kind == TokenKind.DotDotDot) {
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
			if (!isAtEnd(state) && current(state).kind == TokenKind.Colon) {
				advance(state); // consume ':'
				if (current(state).kind == TokenKind.LBrace) {
					const nested = try parseObjectPattern(state);
					props.push(createNode(NodeKind.ObjectPatternProp, {
						propKey: keyToken.value,
						propAlias: nested,
						propDefault: null,
					}, keyToken));
				} else if (current(state).kind == TokenKind.LBracket) {
					const nested = try parseArrayPattern(state);
					props.push(createNode(NodeKind.ObjectPatternProp, {
						propKey: keyToken.value,
						propAlias: nested,
						propDefault: null,
					}, keyToken));
				} else if (isIdentLike(current(state))) {
					const aliasToken = current(state);
					advance(state);
					let aliasDefault: Node | null = null;
					if (!isAtEnd(state) && current(state).kind == TokenKind.Assign) {
						advance(state);
						aliasDefault = try callExprParser(state);
					}
					props.push(createNode(NodeKind.ObjectPatternProp, {
						propKey: keyToken.value,
						propAlias: createNode(NodeKind.Identifier, { name: aliasToken.value }, aliasToken),
						propDefault: aliasDefault,
					}, keyToken));
				}
			} else {
				// Shorthand: { key } — alias is same as key
				let shorthandDefault: Node | null = null;
				if (!isAtEnd(state) && current(state).kind == TokenKind.Assign) {
					advance(state);
					shorthandDefault = try callExprParser(state);
				}
				props.push(createNode(NodeKind.ObjectPatternProp, {
					propKey: keyToken.value,
					propAlias: createNode(NodeKind.Identifier, { name: keyToken.value }, keyToken),
					propDefault: shorthandDefault,
				}, keyToken));
			}
		} else {
			break;
		}
		if (current(state).kind == TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}
	if (current(state).kind == TokenKind.RBrace) { advance(state); }
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
	if (macroName == "comptime" && !isAtEnd(state) && current(state).kind == TokenKind.LBrace) {
		const comptimeBody = try callBlockParser(state);
		return Result.ok(createNode(NodeKind.ComptimeBlock, { comptimeBody }, atToken));
	}

	// Optional arguments: @name(arg1, arg2)
	const args: Node[] = [];
	if (!isAtEnd(state) && current(state).kind == TokenKind.LParen) {
		advance(state); // consume '('
		while (!isAtEnd(state) && current(state).kind != TokenKind.RParen) {
			const arg = try callExprParser(state);
			args.push(arg);
			if (current(state).kind == TokenKind.Comma) {
				advance(state);
			} else {
				break;
			}
		}
		if (current(state).kind == TokenKind.RParen) {
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

// Returns native name or "". Caller handles its own terminator after the call.
function parseOptionalFromClause(state: ParserState): string {
	if (isAtEnd(state) || current(state).kind != TokenKind.From) return "";
	advance(state); // consume 'from'
	if (!isAtEnd(state) && current(state).kind == TokenKind.String) {
		const name = current(state).value;
		advance(state);
		return name;
	}
	return "";
}

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
		TokenKind.Struct => ExternKind.Struct,
		TokenKind.Macro => ExternKind.Macro,
		_ => ExternKind.Invalid,
	};
	if (externKind == ExternKind.Invalid) {
		return Result.err(`Expected declaration keyword after 'extern' at line ${kindToken.line}`);
	}
	advance(state); // consume the keyword

	// For macro: optional '@' prefix
	if (externKind == ExternKind.Macro && !isAtEnd(state) && current(state).kind == TokenKind.At) {
		advance(state);
	}

	// Parse name (includes backtick operator names like `==`, `<`, `[]`)
	const nameToken = current(state);
	if (!isIdentLike(nameToken) && !isPropertyName(nameToken) && nameToken.kind != TokenKind.OperatorIdent) {
		return Result.err(`Expected identifier in extern declaration at line ${nameToken.line}`);
	}
	advance(state);

	// Capture optional generic params: extern function sort<T>(arr: T[]): void
	const genericNames = captureGenericParams(state);

	// Extern functions → FunctionDecl with "extern" in fnFlags (Standard reference: importc pragma)
	if (externKind == ExternKind.Function) {
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
		let fnBody: Node = createNode(NodeKind.BlockStmt, { statements: [] as Node[] }, externToken);
		let nativeName = parseOptionalFromClause(state);
		if (nativeName != "" || (isAtEnd(state) || current(state).kind != TokenKind.LBrace)) {
			consumeSemicolon(state);
		} else {
			fnBody = try callBlockParser(state);
		}

		// Static extensions strip the synthetic typeof param (not a runtime param)
		const isStatic = params.length > 0 && params[0].length > 7 && params[0].slice(0, 7) == "typeof:";

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

	// Extern enum with body: parse as EnumDecl with ExternC flag.
	if (externKind == ExternKind.Enum && !isAtEnd(state) && current(state).kind == TokenKind.LBrace) {
		advance(state); // skip {
		const members: string[] = [];
		const memberLocs: SourceLocation[] = [];
		const values: number[] = [];
		let nextValue: number = 0;
		while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
			const member = current(state);
			if (!isPropertyName(member)) break;
			members.push(member.value);
			memberLocs.push(makeLocFromToken(member));
			advance(state);
			if (!isAtEnd(state) && current(state).kind == TokenKind.Assign) {
				advance(state);
				if (current(state).kind == TokenKind.Number) {
					nextValue = parseFloat(current(state).value);
					advance(state);
				}
			}
			values.push(nextValue);
			nextValue = nextValue + 1;
			if (!isAtEnd(state) && current(state).kind == TokenKind.Comma) advance(state);
		}
		if (!isAtEnd(state) && current(state).kind == TokenKind.RBrace) advance(state);
		const enumNode = createNode(NodeKind.EnumDecl, {
			enumName: nameToken.value,
			enumMembers: members,
			enumValues: values,
			nameLocation: makeLocFromToken(nameToken),
			memberLocations: memberLocs,
		}, externToken);
		enumNode.flags = enumNode.flags | NodeFlag.ExternC;
		return Result.ok(enumNode);
	}

	// Extern interface with field body: parse as InterfaceDecl with ExternC flag.
	// Reuses the full interface resolution pipeline (fields, types, generics).
	// Only applies when body contains fields (name: Type), not methods (name(): Type).
	if ((externKind == ExternKind.Interface || externKind == ExternKind.Struct) && !isAtEnd(state) && current(state).kind == TokenKind.LBrace) {
		const bodyNodeKind = externKind == ExternKind.Struct ? NodeKind.StructDecl : NodeKind.InterfaceDecl;
		// Peek ahead to determine if body has fields or methods
		const savedPos = state.position;
		let hasFieldBody = true;
		advance(state); // skip {
		if (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
			// Check second token after field name: colon = field, lparen = method
			if (isPropertyName(current(state))) {
				advance(state); // skip name
				if (!isAtEnd(state) && current(state).kind == TokenKind.LParen) {
					hasFieldBody = false; // method signature, not field
				}
			}
		}
		state.position = savedPos; // rewind

		if (hasFieldBody) {
			const ifaceResult = parseInterfaceBody(state, nameToken.value, externToken, genericNames, bodyNodeKind, makeLocFromToken(nameToken));
			if (ifaceResult.ok) {
				ifaceResult.value.flags = ifaceResult.value.flags | NodeFlag.ExternC;
				return ifaceResult;
			}
		}
	}

	// Extern class with body: parse as ClassDecl with ExternC flag.
	// Class body supports fields (name: Type) and extern methods (name(...): Type).
	// parseClassMember already handles 'extern' modifier on methods.
	if (externKind == ExternKind.Class && !isAtEnd(state)) {
		// genericNames already captured before extern kind dispatch
		if (genericNames != "") {
			addGenericDecl(nameToken.value, genericNames);
		}
		let extendsName = "";
		if (!isAtEnd(state) && current(state).kind == TokenKind.Extends) {
			advance(state);
			if (isIdentLike(current(state))) { extendsName = current(state).value; advance(state); }
			skipGenericParams(state);
		}
		if (!isAtEnd(state) && current(state).kind == TokenKind.LBrace) {
			advance(state); // skip {
			const members: Node[] = [];
			while (!isAtEnd(state) && current(state).kind != TokenKind.RBrace) {
				if (current(state).kind == TokenKind.Semicolon) { advance(state); continue; }
				const member = try parseClassMember(state);
				members.push(member);
			}
			if (!isAtEnd(state) && current(state).kind == TokenKind.RBrace) advance(state);
			const classNode = createNode(NodeKind.ClassDecl, {
				className: nameToken.value,
				classExtends: extendsName,
				classBody: members,
				nameLocation: makeLocFromToken(nameToken),
			}, externToken);
			classNode.flags = classNode.flags | NodeFlag.ExternC;
			return Result.ok(classNode);
		} else {
			// extern class FILE; — opaque type with optional `from "native"`.
			const externNativeName = parseOptionalFromClause(state);
			consumeSemicolon(state);
			return Result.ok(createNode(NodeKind.ExternDecl, {
				externKind,
				externName: nameToken.value,
				nativeName: externNativeName,
				externType: "",
			}, externToken));
		}
	}

	// Non-function externs: keep ExternDecl node
	skipBalanced(state, TokenKind.LParen, TokenKind.RParen);
	const externType = captureOptionalType(state);
	const externTypeExpr = getLastTypeExpr();

	if (!isAtEnd(state) && current(state).kind == TokenKind.Extends) {
		advance(state);
		skipTypeAnnotation(state);
	}

	// Parse optional 'from "c_name"' clause or body/semicolon
	const externNativeName = parseOptionalFromClause(state);
	if (externNativeName != "") {
		consumeSemicolon(state);
	} else if (!isAtEnd(state) && current(state).kind == TokenKind.LBrace) {
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

	if (current(state).kind != TokenKind.Type) {
		return Result.err(`Expected 'type' after 'distinct' at line ${current(state).line}`);
	}
	advance(state); // consume 'type'

	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected identifier after 'distinct type' at line ${nameToken.line}`);
	}
	advance(state);

	if (current(state).kind != TokenKind.Assign) {
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
		aliasGenericParams: "",
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
	const macroDeclParamTypes = extractParamTypes(raw);

	const macroDeclReturnType = captureOptionalType(state);
	const returnTypeExpr = getLastTypeExpr();

	const body = try callBlockParser(state);

	const node = createNode(NodeKind.MacroDecl, {
		macroDeclName: nameToken.value,
		macroDeclParams,
		macroDeclParamTypes,
		macroDeclReturnType,
		macroDeclBody: body,
	}, macroToken);
	node.typeExpr = returnTypeExpr;
	return Result.ok(node);
}

export function parseConverterDecl(state: ParserState): NodeResult {
	const convToken = current(state);
	advance(state); // consume 'converter'

	const nameToken = current(state);
	if (!isIdentLike(nameToken)) {
		return Result.err(`Expected identifier after 'converter' at line ${nameToken.line}`);
	}
	advance(state);

	const raw = parseParamList(state, nameToken.value);
	const params = extractParamNames(raw);
	const paramTypes = extractParamTypes(raw);
	if (params.length != 1) {
		return Result.err(`converter '${nameToken.value}' must take exactly one parameter at line ${nameToken.line}`);
	}
	if (paramTypes[0] != "Node") {
		return Result.err(`converter '${nameToken.value}' source must be a compile-time type (Node), got '${paramTypes[0]}' at line ${nameToken.line}`);
	}

	const macroDeclReturnType = captureOptionalType(state);
	if (macroDeclReturnType == "") {
		return Result.err(`converter '${nameToken.value}' requires an explicit return type at line ${nameToken.line}`);
	}
	const returnTypeExpr = getLastTypeExpr();

	const body = try callBlockParser(state);

	const node = createNode(NodeKind.MacroDecl, {
		macroDeclName: nameToken.value,
		macroDeclParams: params,
		macroDeclParamTypes: paramTypes,
		macroDeclReturnType,
		macroDeclBody: body,
	}, convToken);
	node.flags = node.flags | NodeFlag.Converter;
	node.typeExpr = returnTypeExpr;
	return Result.ok(node);
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

test "import star as" { assert programOk("import * as ns from \"./lib\";"); }

test "import star as data" {
	const d = stmtAt("import * as ns from \"./lib\";", 0).data as ImportDeclData;
	assert d.importNames[0] == "*";
	assert d.importAliases[0] == "ns";
	assert d.importSource == "./lib";
}

test "export star" { assert programOk("export * from \"./lib\";"); }

test "export star is ExportDecl" { assert stmtKind("export * from \"./lib\";") == NodeKind.ExportDecl; }

test "export star data" {
	const ex = stmtAt("export * from \"./lib\";", 0).data as ExportDeclData;
	const imp = ex.exportedDecl.data as ImportDeclData;
	assert imp.importNames[0] == "*";
	assert imp.importAliases[0] == "*";
	assert imp.importSource == "./lib";
}
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

test "interface optional fn field" { assert programOk("interface Opt { cb?: (x: int32) => int32; }"); }

test "struct optional field rejected" { assert !programOk("struct S { x?: number; }"); }

test "class optional method rejected" { assert !programOk("class C { m?(): void {} }"); }

test "interface extends" { assert programOk("interface Dog extends Animal { breed: string; }"); }

test "struct" { assert programOk("struct Point { x: number; y: number; }"); }

test "struct single field" { assert programOk("struct Id { value: number; }"); }

test "struct generic" { assert programOk("struct Box<T> { value: T; }"); }

test "export struct" { assert programOk("export struct Vec2 { x: number; y: number; }"); }

test "export distinct type" { assert programOk("export distinct type EntityId = number;"); }

test "export distinct is ExportDecl" { assert stmtKind("export distinct type EntityId = number;") == NodeKind.ExportDecl; }

test "export distinct wraps distinct alias" {
	const ex = stmtAt("export distinct type EntityId = number;", 0).data as ExportDeclData;
	const d = ex.exportedDecl.data as TypeAliasDeclData;
	assert d.aliasIsDistinct;
	assert d.aliasName == "EntityId";
}

test "extern struct" { assert programOk("extern struct NativePoint { x: float64; y: float64; }"); }

// Param features — exercises parseParamList + skipDefaultValue
test "rest param" { assert programOk("function f(...args) { return args; }"); }

test "default param" { assert programOk("function f(x = 5) { return x; }"); }

test "default param complex" { assert programOk("function f(x = [1, 2], y = {a: 3}) {}"); }

test "typed param" { assert programOk("function f(x: number, y: string) {}"); }

test "ref param" { assert programOk("function update(ref v: number): void {}"); }

test "ref struct param" { assert programOk("struct Vec2 { x: number; y: number; }\nfunction scale(ref v: Vec2): void {}"); }
// Enum with complex values — exercises skipDefaultValue depth tracking
test "enum complex value" { assert programOk("enum E { A = fn(1, 2), B = arr[0] }"); }
// Var declarations
test "var decl" { assert programOk("var x = 1;"); }

test "var is VariableDecl" { assert stmtKind("var x = 1;") == NodeKind.VariableDecl; }

test "var declKind is Var" {
	const d = stmtAt("var x = 1;", 0).data as VariableDeclData;
	assert d.declKind == DeclKind.Var;
}

test "var declName" {
	const d = stmtAt("var x = 1;", 0).data as VariableDeclData;
	assert d.declName == "x";
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

test "extern function is FunctionDecl" { assert stmtKind("extern function f(): void;") == NodeKind.FunctionDecl; }

test "extern function has extern flag" {
	const d = stmtAt("extern function printf(fmt: string): void;", 0).data as FunctionDeclData;
	assert d.fnFlags == "extern";
}

test "extern const is ExternDecl" { assert stmtKind("extern const STDIN: int32;") == NodeKind.ExternDecl; }

test "extern name field" {
	const d = stmtAt("extern const STDIN: FILE;", 0).data as ExternDeclData;
	assert d.externName == "STDIN";
	assert d.externType == "FILE";
}

test "extern class kind" {
	// extern class with body → ClassDecl with ExternC flag
	assert stmtKind("extern class FILE {}") == NodeKind.ClassDecl;
}

test "extern var with type and from" {
	const d = stmtAt("extern var errno: int32 from \"ms_errno\";", 0).data as ExternDeclData;
	assert d.externKind == ExternKind.Var;
	assert d.externName == "errno";
	assert d.externType == "int32";
	assert d.nativeName == "ms_errno";
}

test "extern const no from" {
	const d = stmtAt("extern const STDIN: FILE;", 0).data as ExternDeclData;
	assert d.externKind == ExternKind.Const;
	assert d.nativeName == "";
}

test "extern class opaque" {
	const d = stmtAt("extern class FILE;", 0).data as ExternDeclData;
	assert d.externKind == ExternKind.Class;
	assert d.externType == "";
}

test "extern generics" { assert programOk("extern function sort<T>(arr: T[]): void;"); }

test "extern extends" { assert programOk("extern class Derived extends Base {}"); }

test "extern error" { assert !programOk("extern 42"); }

test "export extern function" { assert programOk("export extern function foo(x: number): void;"); }

test "export extern function is ExportDecl" { assert stmtKind("export extern function foo(): void;") == NodeKind.ExportDecl; }

test "extern function from" { assert programOk("extern function floor(x: number): number from \"msFloor\";"); }

test "extern function from nativeName" {
	const d = stmtAt("extern function floor(x: number): number from \"msFloor\";", 0).data as FunctionDeclData;
	assert d.fnName == "floor";
	assert d.nativeName == "msFloor";
	assert d.fnFlags == "extern";
}

test "extern function without from" {
	const d = stmtAt("extern function printf(fmt: string): void;", 0).data as FunctionDeclData;
	assert d.fnName == "printf";
	assert d.nativeName == "";
}

// Distinct type
test "distinct type" { assert programOk("distinct type UserId = number;"); }

test "distinct type string" { assert programOk("distinct type Email = string;"); }

test "distinct is TypeAliasDecl" { assert stmtKind("distinct type X = number;") == NodeKind.TypeAliasDecl; }

test "distinct flag true" {
	const d = stmtAt("distinct type UserId = number;", 0).data as TypeAliasDeclData;
	assert d.aliasIsDistinct;
}

test "distinct name field" {
	const d = stmtAt("distinct type Email = string;", 0).data as TypeAliasDeclData;
	assert d.aliasName == "Email";
}

test "type alias not distinct" {
	const d = stmtAt("type ID = number;", 0).data as TypeAliasDeclData;
	assert !d.aliasIsDistinct;
}
// Macro declaration
test "macro decl" { assert programOk("macro deriveEq(target) { return target; }"); }

test "macro is MacroDecl" { assert stmtKind("macro foo(x) { return x; }") == NodeKind.MacroDecl; }

test "macro name field" {
	const d = stmtAt("macro deriveEq(target) { return target; }", 0).data as MacroDeclData;
	assert d.macroDeclName == "deriveEq";
}

test "macro multi param" { assert programOk("macro foo(a, b, c) { return a; }"); }

test "macro params field" {
	const d = stmtAt("macro foo(a, b, c) { return a; }", 0).data as MacroDeclData;
	assert d.macroDeclParams.length == 3;
}

test "macro body is block" {
	const d = stmtAt("macro foo(x) { return x; }", 0).data as MacroDeclData;
	assert d.macroDeclBody.kind == NodeKind.BlockStmt;
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
	assert d.fnFlags == "ext:s:string";
}

test "extension keeps receiver in params" {
	const n = stmtAt("function f(this s: string) { return 1; }", 0);
	const d = n.data as FunctionDeclData;
	assert d.params.length == 1;
	assert d.params[0] == "s";
}

test "extension with extra params" {
	const n = stmtAt("function f(this s: string, n: number) { return 1; }", 0);
	const d = n.data as FunctionDeclData;
	assert d.params.length == 2;
	assert d.params[0] == "s";
	assert d.params[1] == "n";
}

test "no receiver flags empty" {
	const n = stmtAt("function f(x: number) { return 1; }", 0);
	const d = n.data as FunctionDeclData;
	assert d.fnFlags == "";
}

test "object destructure" { assert stmtKind("const {a, b} = obj;") == NodeKind.DestructuringDecl; }

test "array destructure" { assert programOk("const [x, y] = arr;"); }

test "nested object" { assert programOk("const {a: {b, c}} = obj;"); }

test "object rest" { assert programOk("const {a, ...rest} = obj;"); }

test "array rest" { assert programOk("const [first, ...rest] = arr;"); }

test "let destructure" { assert programOk("let {x, y} = point;"); }

test "object destructure shorthand default" {
	const dd = stmtAt("const {a = 1} = obj;", 0).data as DestructuringDeclData;
	const pat = dd.destrPattern.data as ObjectPatternData;
	const prop = pat.patternProps[0].data as ObjectPatternPropData;
	assert prop.propKey == "a";
	assert prop.propDefault != null;
}

test "object destructure alias default" {
	const dd = stmtAt("const {k: alias = 2} = obj;", 0).data as DestructuringDeclData;
	const pat = dd.destrPattern.data as ObjectPatternData;
	const prop = pat.patternProps[0].data as ObjectPatternPropData;
	assert prop.propKey == "k";
	assert prop.propDefault != null;
}

test "object destructure without default" {
	const dd = stmtAt("const {a} = obj;", 0).data as DestructuringDeclData;
	const pat = dd.destrPattern.data as ObjectPatternData;
	const prop = pat.patternProps[0].data as ObjectPatternPropData;
	assert prop.propDefault == null;
}

test "array destructure default" {
	const dd = stmtAt("const [x = 3] = arr;", 0).data as DestructuringDeclData;
	const pat = dd.destrPattern.data as ArrayPatternData;
	assert pat.patternDefaults.length == 1;
	assert pat.patternDefaults[0] != null;
}

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

test "multi generic" { assert programOk("class HashMap<K, V> { lookup(k: K): V {} }"); }

test "implements" { assert programOk("class Foo implements Bar {}"); }
