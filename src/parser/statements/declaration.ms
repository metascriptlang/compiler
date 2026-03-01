// Declaration Parsers - variable, function, import, export, type alias, enum, interface
// Uses callback injection via util.ms to avoid circular imports

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, DeclKind, NodeData, createNode, VariableDeclData, ExternDeclData, TypeAliasDeclData, MacroDeclData, FunctionDeclData, PropertyDeclData } from "../../ast/node";
import { ParserState, current, advance, isAtEnd, skipDestructurePattern, consumeSemicolon, skipGenericParams, captureGenericParams, skipBalanced, addGenericDecl, updateGenericDeclFields } from "../context";
import { skipTypeAnnotation } from "../typeAnnotation";
import { parseParamList, extractParamNames, extractParamTypes, captureOptionalType, skipDefaultValue, skipOptionalType } from "../util";
import { callBlockParser, callExprParser } from "./callbacks";
import { sliceStr } from "../../utils/string";
import { programOk, stmtKind, stmtAt } from "./validation";
import { test, check, testGroup } from "std/testing";

type NodeResult = Result<Node, string>;

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
			return Result.err(`Expected '=' after destructuring pattern at line ${current(state).line.toString()}`);
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
			return Result.err(`Expected '=' after destructuring pattern at line ${current(state).line.toString()}`);
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
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected identifier after ${keyword.value} at line ${nameToken.line.toString()}`);
	}

	advance(state);
	// Optional type annotation: const x: number = ...
	const declType = captureOptionalType(state);

	if (current(state).kind !== TokenKind.Assign) {
		return Result.err(`Expected '=' in variable declaration at line ${current(state).line.toString()}`);
	}

	advance(state);
	const init = try callExprParser(state);
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.VariableDecl, {
		declName: nameToken.value,
		declType,
		initializer: init,
		declKind: match (keyword.kind) { TokenKind.Const => DeclKind.Const, TokenKind.Var => DeclKind.Var, _ => DeclKind.Let },
	}, keyword));
}

// ===== Specifier List Helper =====
// Note: string[] is a value type in C (struct copy), so we can't pass arrays
// as out-parameters. Instead, we inline the parsing loop at each call site.

// ===== Helpers =====

function stripFirstParam(arr: string[]): string[] {
	const result: string[] = [];
	for (let i = 1; i < arr.length; i += 1) { result.push(arr[i]); }
	return result;
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
	// Accept Ident or TemplateNoSub (backtick-stropped operator name, e.g. `[]`)
	if (nameToken.kind !== TokenKind.Ident && nameToken.kind !== TokenKind.TemplateNoSub) {
		return Result.err(`Expected function name at line ${nameToken.line.toString()}`);
	}

	advance(state);
	// Capture optional generic params: function id<T>(x: T): T
	const genericNames = captureGenericParams(state);
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after function name at line ${current(state).line.toString()}`);
	}

	const raw = parseParamList(state);
	const params = extractParamNames(raw);
	const fnParamTypes = extractParamTypes(raw);
	// Check for instance extension: first param has "this:" prefix
	if (params.length > 0 && params[0].length > 5) {
		const prefix = sliceStr(params[0], 0, 5);
		if (prefix === "this:") {
			const receiverName = sliceStr(params[0], 5, params[0].length);
			const receiverType = fnParamTypes[0];
			if (flags === "") {
				flags = "ext:" + receiverName + ":" + receiverType;
			} else {
				flags = flags + "|ext:" + receiverName + ":" + receiverType;
			}
			params[0] = receiverName;
		}
	}
	// Check for static extension: first param has "typeof:" prefix
	// Static extensions strip the synthetic typeof param (not a runtime param)
	if (params.length > 0 && params[0].length > 7 && sliceStr(params[0], 0, 7) === "typeof:") {
		const staticType = sliceStr(params[0], 7, params[0].length);
		if (flags === "") { flags = "sext:" + staticType; }
		else { flags = flags + "|sext:" + staticType; }
		// Encode generic param names in flags: "gen:T,U"
		if (genericNames !== "") { flags = flags + "|gen:" + genericNames; }
		const fnReturnType = captureOptionalType(state);
		return Result.ok(createNode(NodeKind.FunctionDecl, {
			fnName: nameToken.value,
			params: stripFirstParam(params),
			fnParamTypes: stripFirstParam(fnParamTypes),
			fnBody: try callBlockParser(state),
			fnFlags: flags,
			fnReturnType,
		}, fnToken));
	}
	// Encode generic param names in flags: "gen:T,U"
	if (genericNames !== "") {
		if (flags === "") { flags = "gen:" + genericNames; }
		else { flags = flags + "|gen:" + genericNames; }
	}
	// Optional return type annotation: function f(): string { ... }
	const fnReturnType = captureOptionalType(state);

	return Result.ok(createNode(NodeKind.FunctionDecl, {
		fnName: nameToken.value,
		params,
		fnParamTypes,
		fnBody: try callBlockParser(state),
		fnFlags: flags,
		fnReturnType,
	}, fnToken));
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
		return Result.err(`Expected '{' or string after 'import' at line ${current(state).line.toString()}`);
	}

	advance(state);
	const names: string[] = [];
	const aliases: string[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		const specifier = current(state);
		if (specifier.kind !== TokenKind.Ident) { break; }
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

	if (current(state).kind !== TokenKind.RBrace) {
		return Result.err(`Expected '}' after import specifiers at line ${current(state).line.toString()}`);
	}

	advance(state);
	if (current(state).kind !== TokenKind.From) {
		return Result.err(`Expected 'from' after import specifiers at line ${current(state).line.toString()}`);
	}

	advance(state);
	if (current(state).kind !== TokenKind.String) {
		return Result.err(`Expected module path string at line ${current(state).line.toString()}`);
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
		const names: string[] = [];
		const aliases: string[] = [];
		while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
			const specifier = current(state);
			if (specifier.kind !== TokenKind.Ident) { break; }
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
		if (current(state).kind === TokenKind.RBrace) { advance(state); }
		if (current(state).kind !== TokenKind.From) {
			return Result.err(`Expected 'from' after export specifiers at line ${current(state).line.toString()}`);
		}
		advance(state);
		if (current(state).kind !== TokenKind.String) {
			return Result.err(`Expected module path string at line ${current(state).line.toString()}`);
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

	return Result.err(`Expected declaration after 'export' at line ${current(state).line.toString()}`);
}

// ===== Type Alias Declaration =====
// syntax: 'type' ID '=' type ';'

export function parseTypeAliasDecl(state: ParserState): NodeResult {
	const typeToken = current(state);

	advance(state);
	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected identifier after 'type' at line ${nameToken.line.toString()}`);
	}

	advance(state);
	if (current(state).kind !== TokenKind.Assign) {
		return Result.err(`Expected '=' in type alias at line ${current(state).line.toString()}`);
	}

	advance(state);
	const typeStart = state.position;
	skipTypeAnnotation(state);
	const typeEnd = state.position;
	let aliasType = "";
	for (let ti = typeStart; ti < typeEnd; ti += 1) {
		if (ti > typeStart) { aliasType = aliasType + " "; }
		aliasType = aliasType + state.tokens[ti].value;
	}
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.TypeAliasDecl, {
		aliasName: nameToken.value,
		aliasType,
		aliasIsDistinct: false,
	}, typeToken));
}

// ===== Enum Declaration =====
// syntax: 'enum' ID '{' (ID ('=' expr)? ',')* '}'

export function parseEnumDecl(state: ParserState): NodeResult {
	const enumToken = current(state);

	advance(state);
	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected identifier after 'enum' at line ${nameToken.line.toString()}`);
	}

	advance(state);
	if (current(state).kind !== TokenKind.LBrace) {
		return Result.err(`Expected '{' after enum name at line ${current(state).line.toString()}`);
	}

	advance(state);
	const members: string[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		const member = current(state);
		if (member.kind !== TokenKind.Ident) {
			return Result.err(`Expected enum member name at line ${member.line.toString()}`);
		}

		members.push(member.value);
		advance(state);
		// Optional value: A = 1 — skip balanced value expression
		if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
			advance(state);
			skipDefaultValue(state);
		}

		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		}
	}

	if (current(state).kind !== TokenKind.RBrace) {
		return Result.err(`Expected '}' after enum members at line ${current(state).line.toString()}`);
	}

	advance(state);
	return Result.ok(createNode(NodeKind.EnumDecl, {
		enumName: nameToken.value,
		enumMembers: members,
	}, enumToken));
}

// ===== Interface Declaration =====
// syntax: 'interface' ID ('<' params '>')? ('extends' type)? '{' members '}'

export function parseInterfaceDecl(state: ParserState): NodeResult {
	const ifaceToken = current(state);

	advance(state);
	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected identifier after 'interface' at line ${nameToken.line.toString()}`);
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
		return Result.err(`Expected '{' after interface name at line ${current(state).line.toString()}`);
	}

	advance(state);
	const fields: string[] = [];
	const fieldTypes: string[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
		const field = current(state);
		if (field.kind !== TokenKind.Ident) {
			return Result.err(`Expected field name in interface at line ${field.line.toString()}`);
		}

		fields.push(field.value);
		advance(state);
		// Optional marker: field?: Type
		if (!isAtEnd(state) && current(state).kind === TokenKind.Question) {
			advance(state);
		}

		// Colon + type annotation — capture it
		fieldTypes.push(captureOptionalType(state));

		// Skip semicolons and commas between members
		if (!isAtEnd(state) && (current(state).kind === TokenKind.Semicolon || current(state).kind === TokenKind.Comma)) {
			advance(state);
		}
	}

	if (current(state).kind !== TokenKind.RBrace) {
		return Result.err(`Expected '}' after interface body at line ${current(state).line.toString()}`);
	}

	advance(state);

	// Store field info in generic decl side-channel for checker to use
	if (ifaceIsGeneric) {
		let fnJoined = "";
		let ftJoined = "";
		for (let fi = 0; fi < fields.length; fi += 1) {
			if (fi > 0) { fnJoined = fnJoined + "|"; ftJoined = ftJoined + "|"; }
			fnJoined = fnJoined + fields[fi];
			if (fi < fieldTypes.length) { ftJoined = ftJoined + fieldTypes[fi]; }
		}
		updateGenericDeclFields(nameToken.value, fnJoined, ftJoined);
	}

	return Result.ok(createNode(NodeKind.InterfaceDecl, {
		interfaceName: nameToken.value,
		interfaceFields: fields,
		interfaceFieldTypes: fieldTypes,
	}, ifaceToken));
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
		return Result.err(`Expected 'class' at line ${current(state).line.toString()}`);
	}
	advance(state);

	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected class name at line ${nameToken.line.toString()}`);
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
		if (current(state).kind === TokenKind.Ident) {
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
		return Result.err(`Expected '{' after class declaration at line ${current(state).line.toString()}`);
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
		for (let mi = 0; mi < members.length; mi += 1) {
			const mk = members[mi].kind;
			if (mk === NodeKind.PropertyDecl) {
				const pd = members[mi].data as PropertyDeclData;
				if (fnJoined !== "") { fnJoined = fnJoined + "|"; ftJoined = ftJoined + "|"; }
				fnJoined = fnJoined + pd.propName;
				ftJoined = ftJoined + pd.propType;
			}
		}
		updateGenericDeclFields(nameToken.value, fnJoined, ftJoined);
	}

	return Result.ok(createNode(NodeKind.ClassDecl, {
		className: nameToken.value,
		classExtends: extendsName,
		classBody: members,
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

	// Check for async modifier on methods
	let memberFlags = "";
	if (current(state).kind === TokenKind.Async) {
		memberFlags = "async";
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
		state.tokens[state.position + 1].kind === TokenKind.Ident) {
		return parseClassAccessor(state, memberIsStatic, memberFlags);
	}

	// Regular member: name followed by ( for method, or : / = / ; for property
	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected member name in class at line ${nameToken.line.toString()}`);
	}
	advance(state);

	// Optional question mark
	if (!isAtEnd(state) && current(state).kind === TokenKind.Question) {
		advance(state);
	}

	// Method — early return
	if (!isAtEnd(state) && current(state).kind === TokenKind.LParen) {
		return parseClassMethodBody(state, nameToken, memberIsStatic, memberFlags);
	}

	// Property — capture type, skip initializer tokens manually
	const propType = captureOptionalType(state);
	if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
		advance(state);
		skipDefaultValue(state);
	}
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.PropertyDecl, {
		propName: nameToken.value,
		propType,
		propIsStatic: memberIsStatic,
	}, nameToken));
}

// parseParamList and skipDefaultValue imported from ../util


function parseClassConstructor(state: ParserState): NodeResult {
	const ctorToken = current(state);
	advance(state);
	const raw = parseParamList(state);
	const ctorParams = extractParamNames(raw);
	const ctorParamTypes = extractParamTypes(raw);
	const body = try callBlockParser(state);
	return Result.ok(createNode(NodeKind.ConstructorDecl, {
		ctorParams,
		ctorParamTypes,
		ctorBody: body,
	}, ctorToken));
}

function parseClassAccessor(state: ParserState, isStatic: boolean, flags: string): NodeResult {
	const accToken = current(state);
	const accKind = current(state).value;
	advance(state);
	const accName = current(state).value;
	advance(state);
	const raw = parseParamList(state);
	const methodParams = extractParamNames(raw);
	const methodParamTypes = extractParamTypes(raw);
	const methodReturnType = captureOptionalType(state);
	const body = try callBlockParser(state);
	return Result.ok(createNode(NodeKind.MethodDecl, {
		methodName: accKind + "_" + accName,
		methodParams,
		methodParamTypes,
		methodBody: body,
		methodIsStatic: isStatic,
		methodFlags: flags,
		methodReturnType,
	}, accToken));
}

function parseClassMethodBody(state: ParserState, nameToken: Token, isStatic: boolean, flags: string): NodeResult {
	const raw = parseParamList(state);
	const methodParams = extractParamNames(raw);
	const methodParamTypes = extractParamTypes(raw);
	// Optional return type
	const methodReturnType = captureOptionalType(state);
	// Abstract methods have no body — just semicolon
	if (current(state).kind === TokenKind.Semicolon) {
		consumeSemicolon(state);
		return Result.ok(createNode(NodeKind.MethodDecl, {
			methodName: nameToken.value,
			methodParams,
			methodParamTypes,
			methodBody: createNode(NodeKind.BlockStmt, { statements: [] }, nameToken),
			methodIsStatic: isStatic,
			methodFlags: flags,
			methodReturnType,
		}, nameToken));
	}
	const body = try callBlockParser(state);
	return Result.ok(createNode(NodeKind.MethodDecl, {
		methodName: nameToken.value,
		methodParams,
		methodParamTypes,
		methodBody: body,
		methodIsStatic: isStatic,
		methodFlags: flags,
		methodReturnType,
	}, nameToken));
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
			if (restIdent.kind === TokenKind.Ident) {
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
		} else if (current(state).kind === TokenKind.Ident) {
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
			if (restIdent.kind === TokenKind.Ident) {
				advance(state);
				props.push(createNode(NodeKind.SpreadExpr, {
					spreadArg: createNode(NodeKind.Identifier, { name: restIdent.value }, restIdent),
				}, spreadToken));
			}
		} else if (current(state).kind === TokenKind.Ident) {
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
				} else if (current(state).kind === TokenKind.Ident) {
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
		TokenKind.Function => "function",
		TokenKind.Class => "class",
		TokenKind.Const => "const",
		TokenKind.Var => "var",
		TokenKind.Let => "let",
		TokenKind.Type => "type",
		TokenKind.Enum => "enum",
		TokenKind.Interface => "interface",
		TokenKind.Macro => "macro",
		_ => "",
	};
	if (externKind === "") {
		return Result.err(`Expected declaration keyword after 'extern' at line ${kindToken.line.toString()}`);
	}
	advance(state); // consume the keyword

	// For macro: optional '@' prefix
	if (externKind === "macro" && !isAtEnd(state) && current(state).kind === TokenKind.At) {
		advance(state);
	}

	// Parse name
	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected identifier in extern declaration at line ${nameToken.line.toString()}`);
	}
	advance(state);

	// Skip optional generic params: <T, U>
	skipGenericParams(state);

	// Skip optional param list: (params)
	skipBalanced(state, TokenKind.LParen, TokenKind.RParen);

	// Skip optional return type: : type
	skipOptionalType(state);

	// Skip optional 'extends' clause
	if (!isAtEnd(state) && current(state).kind === TokenKind.Extends) {
		advance(state);
		skipTypeAnnotation(state);
	}

	// Body or semicolon
	if (!isAtEnd(state) && current(state).kind === TokenKind.LBrace) {
		skipBalanced(state, TokenKind.LBrace, TokenKind.RBrace);
	} else {
		consumeSemicolon(state);
	}

	return Result.ok(createNode(NodeKind.ExternDecl, {
		externKind,
		externName: nameToken.value,
	}, externToken));
}

// ===== Distinct Type Declaration =====
// syntax: 'distinct' 'type' ID '=' type ';'

export function parseDistinctTypeDecl(state: ParserState): NodeResult {
	const distinctToken = current(state);
	advance(state); // consume 'distinct'

	if (current(state).kind !== TokenKind.Type) {
		return Result.err(`Expected 'type' after 'distinct' at line ${current(state).line.toString()}`);
	}
	advance(state); // consume 'type'

	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected identifier after 'distinct type' at line ${nameToken.line.toString()}`);
	}
	advance(state);

	if (current(state).kind !== TokenKind.Assign) {
		return Result.err(`Expected '=' in distinct type declaration at line ${current(state).line.toString()}`);
	}
	advance(state);
	const dTypeStart = state.position;
	skipTypeAnnotation(state);
	const dTypeEnd = state.position;
	let distinctAliasType = "";
	for (let di = dTypeStart; di < dTypeEnd; di += 1) {
		if (di > dTypeStart) { distinctAliasType = distinctAliasType + " "; }
		distinctAliasType = distinctAliasType + state.tokens[di].value;
	}
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.TypeAliasDecl, {
		aliasName: nameToken.value,
		aliasType: distinctAliasType,
		aliasIsDistinct: true,
	}, distinctToken));
}

// ===== Macro Declaration =====
// syntax: 'macro' ID '(' params ')' (':' type)? block

export function parseMacroDecl(state: ParserState): NodeResult {
	const macroToken = current(state);
	advance(state); // consume 'macro'

	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected identifier after 'macro' at line ${nameToken.line.toString()}`);
	}
	advance(state);

	const raw = parseParamList(state);
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

testGroup("Stmt Declarations", () => {
	// Variable — const vs let
	test("const decl", () => { check(programOk("const x = 42;")); });
	test("let decl", () => { check(programOk("let y = 0;")); });
	// Function — empty, with params, with body
	test("function empty", () => { check(programOk("function f() { }")); });
	test("function multi-stmt", () => { check(programOk("function f() { const x = 1; return x; }")); });
	// Import — distinct paths: named, aliased, side-effect
	test("import named", () => { check(programOk("import { Token, TokenKind } from \"./token\";")); });
	test("import aliased", () => { check(programOk("import { Token as T } from \"./token\";")); });
	test("import side-effect", () => { check(programOk("import \"./polyfill\";")); });
	// Export — distinct paths: decl, re-export, re-export aliased
	test("export function", () => { check(programOk("export function f() { return 1; }")); });
	test("export const", () => { check(programOk("export const x = 42;")); });
	test("re-export", () => { check(programOk("export { Node, NodeKind } from \"./node\";")); });
	test("re-export aliased", () => { check(programOk("export { Token as T } from \"./token\";")); });
	// Type alias — distinct paths: simple, generic, union, function type
	test("type simple", () => { check(programOk("type ID = number;")); });
	test("type generic", () => { check(programOk("type NodeResult = Result<Node, string>;")); });
	test("type leading pipe", () => { check(programOk("type Data = | { x: number } | { y: string };")); });
	test("type function", () => { check(programOk("type Handler = (a: string) => void;")); });
	// Enum
	test("enum", () => { check(programOk("enum Color { Red, Green, Blue }")); });
	test("enum with values", () => { check(programOk("enum Status { Active = 1, Inactive = 0 }")); });
	// Interface — distinct paths: simple, optional, extends
	test("interface", () => { check(programOk("interface Point { x: number; y: number; }")); });
	test("interface optional", () => { check(programOk("interface Opt { value?: number; }")); });
	test("interface extends", () => { check(programOk("interface Dog extends Animal { breed: string; }")); });
	// Param features — exercises parseParamList + skipDefaultValue
	test("rest param", () => { check(programOk("function f(...args) { return args; }")); });
	test("default param", () => { check(programOk("function f(x = 5) { return x; }")); });
	test("default param complex", () => { check(programOk("function f(x = [1, 2], y = {a: 3}) {}")); });
	test("typed param", () => { check(programOk("function f(x: number, y: string) {}")); });
	// Enum with complex values — exercises skipDefaultValue depth tracking
	test("enum complex value", () => { check(programOk("enum E { A = fn(1, 2), B = arr[0] }")); });
	// Var declarations
	test("var decl", () => { check(programOk("var x = 1;")); });
	test("var is VariableDecl", () => { check(stmtKind("var x = 1;") === NodeKind.VariableDecl); });
	test("var declKind is Var", () => {
		const d = stmtAt("var x = 1;", 0).data as VariableDeclData;
		check(d.declKind === DeclKind.Var);
	});
	test("var declName", () => {
		const d = stmtAt("var x = 1;", 0).data as VariableDeclData;
		check(d.declName === "x");
	});
	test("var typed", () => { check(programOk("var x: number = 1;")); });
	// Extern declarations — all 9 kinds
	test("extern function", () => { check(programOk("extern function printf(fmt: string): void;")); });
	test("extern class empty", () => { check(programOk("extern class FILE {}")); });
	test("extern const", () => { check(programOk("extern const STDIN: FILE;")); });
	test("extern enum", () => { check(programOk("extern enum Color { Red, Green }")); });
	test("extern type", () => { check(programOk("extern type Ptr;")); });
	test("extern var", () => { check(programOk("extern var errno: number;")); });
	test("extern let", () => { check(programOk("extern let counter: number;")); });
	test("extern interface", () => { check(programOk("extern interface Stream { read(): number; }")); });
	test("extern macro", () => { check(programOk("extern macro @inject;")); });
	test("extern is ExternDecl", () => { check(stmtKind("extern function f(): void;") === NodeKind.ExternDecl); });
	test("extern kind field", () => {
		const d = stmtAt("extern function printf(fmt: string): void;", 0).data as ExternDeclData;
		check(d.externKind === "function");
	});
	test("extern name field", () => {
		const d = stmtAt("extern const STDIN: FILE;", 0).data as ExternDeclData;
		check(d.externName === "STDIN");
	});
	test("extern class kind", () => {
		const d = stmtAt("extern class FILE {}", 0).data as ExternDeclData;
		check(d.externKind === "class");
	});
	test("extern generics", () => { check(programOk("extern function sort<T>(arr: T[]): void;")); });
	test("extern extends", () => { check(programOk("extern class Derived extends Base {}")); });
	test("extern error", () => { check(!programOk("extern 42")); });
	// Distinct type
	test("distinct type", () => { check(programOk("distinct type UserId = number;")); });
	test("distinct type string", () => { check(programOk("distinct type Email = string;")); });
	test("distinct is TypeAliasDecl", () => { check(stmtKind("distinct type X = number;") === NodeKind.TypeAliasDecl); });
	test("distinct flag true", () => {
		const d = stmtAt("distinct type UserId = number;", 0).data as TypeAliasDeclData;
		check(d.aliasIsDistinct);
	});
	test("distinct name field", () => {
		const d = stmtAt("distinct type Email = string;", 0).data as TypeAliasDeclData;
		check(d.aliasName === "Email");
	});
	test("type alias not distinct", () => {
		const d = stmtAt("type ID = number;", 0).data as TypeAliasDeclData;
		check(!d.aliasIsDistinct);
	});
	// Macro declaration
	test("macro decl", () => { check(programOk("macro deriveEq(target) { return target; }")); });
	test("macro is MacroDecl", () => { check(stmtKind("macro foo(x) { return x; }") === NodeKind.MacroDecl); });
	test("macro name field", () => {
		const d = stmtAt("macro deriveEq(target) { return target; }", 0).data as MacroDeclData;
		check(d.macroDeclName === "deriveEq");
	});
	test("macro multi param", () => { check(programOk("macro foo(a, b, c) { return a; }")); });
	test("macro params field", () => {
		const d = stmtAt("macro foo(a, b, c) { return a; }", 0).data as MacroDeclData;
		check(d.macroDeclParams.length === 3);
	});
	test("macro body is block", () => {
		const d = stmtAt("macro foo(x) { return x; }", 0).data as MacroDeclData;
		check(d.macroDeclBody.kind === NodeKind.BlockStmt);
	});
	test("macro return type", () => { check(programOk("macro foo(): Node { return x; }")); });
	test("macro empty params", () => { check(programOk("macro noop() { }")); });
});

testGroup("Async/Generator Decl", () => {
	test("async function", () => { check(programOk("async function f() {}")); });
	test("generator function", () => { check(programOk("function* gen() { yield 1; }")); });
	test("async generator", () => { check(programOk("async function* both() { yield 1; }")); });
	test("export async", () => { check(programOk("export async function f() {}")); });
});

testGroup("Extension Methods", () => {
	test("extension parses", () => {
		check(programOk("function f(this s: string) { return 1; }"));
	});
	test("extension flags", () => {
		const n = stmtAt("function f(this s: string) { return 1; }", 0);
		const d = n.data as FunctionDeclData;
		check(d.fnFlags === "ext:s:string");
	});
	test("extension keeps receiver in params", () => {
		const n = stmtAt("function f(this s: string) { return 1; }", 0);
		const d = n.data as FunctionDeclData;
		check(d.params.length === 1);
		check(d.params[0] === "s");
	});
	test("extension with extra params", () => {
		const n = stmtAt("function f(this s: string, n: number) { return 1; }", 0);
		const d = n.data as FunctionDeclData;
		check(d.params.length === 2);
		check(d.params[0] === "s");
		check(d.params[1] === "n");
	});
	test("no receiver flags empty", () => {
		const n = stmtAt("function f(x: number) { return 1; }", 0);
		const d = n.data as FunctionDeclData;
		check(d.fnFlags === "");
	});
});

testGroup("Destructuring Decl", () => {
	test("object destructure", () => { check(stmtKind("const {a, b} = obj;") === NodeKind.DestructuringDecl); });
	test("array destructure", () => { check(programOk("const [x, y] = arr;")); });
	test("nested object", () => { check(programOk("const {a: {b, c}} = obj;")); });
	test("object rest", () => { check(programOk("const {a, ...rest} = obj;")); });
	test("array rest", () => { check(programOk("const [first, ...rest] = arr;")); });
	test("let destructure", () => { check(programOk("let {x, y} = point;")); });
	test("func destr param", () => { check(programOk("function f({x, y}) { return x; }")); });
	test("func array param", () => { check(programOk("function f([a, b]) { return a; }")); });
	test("arrow destr param", () => { check(programOk("const f = ({x}) => x;")); });
});

testGroup("Stmt Class", () => {
	// Distinct member types
	test("property", () => { check(programOk("class Foo { name: string; }")); });
	test("method", () => { check(programOk("class Foo { greet() { return 1; } }")); });
	test("constructor", () => { check(programOk("class Foo { constructor(x: number) { this.x = x; } }")); });
	// Modifiers — each tests a distinct parser path
	test("extends", () => { check(programOk("class Dog extends Animal { bark() { return 1; } }")); });
	test("static", () => { check(programOk("class Foo { static create() { return 1; } }")); });
	test("abstract", () => { check(programOk("abstract class Shape { abstract area(): number; }")); });
	test("getter setter", () => { check(programOk("class Foo { get name() { return 1; } set name(v: string) { this.x = v; } }")); });
	test("export class", () => { check(programOk("export class Foo { x: number; }")); });
	test("async method", () => { check(programOk("class Foo { async fetch() {} }")); });
	test("generator method", () => { check(programOk("class Foo { *items() { yield 1; } }")); });
	// Complex
	test("multi members", () => { check(programOk("class Point { x: number; y: number; toString() { return 1; } }")); });
	test("constructor public", () => { check(programOk("class Foo { constructor(public name: string) { } }")); });
	// Generic classes — exercises skipGenericParams in context.ms
	test("generic class", () => { check(programOk("class Container<T> { value: T; }")); });
	test("generic extends", () => { check(programOk("class List<T> extends Base<T> {}")); });
	test("multi generic", () => { check(programOk("class Map<K, V> { lookup(k: K): V {} }")); });
	test("implements", () => { check(programOk("class Foo implements Bar {}")); });
});
