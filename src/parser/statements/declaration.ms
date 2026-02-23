// Declaration Parsers - variable, function, import, export, type alias, enum, interface
// Uses callback injection via util.ms to avoid circular imports

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, createNode } from "../../ast/node";
import { ParserState, current, advance, isAtEnd, skipDestructurePattern, consumeSemicolon, skipGenericParams } from "../context";
import { skipTypeAnnotation } from "../typeAnnotation";
import { parseParamList, skipDefaultValue } from "../util";
import { callBlockParser, callExprParser, programOk, stmtKind } from "./util";
import { test, check, testGroup } from "std/testing";

type NodeResult = Result<Node, string>;

// ===== Variable Declaration =====
// const x = expr; | const x: Type = expr;

export function parseVariableDecl(state: ParserState): NodeResult {
	const keyword = current(state);
	advance(state);

	// Destructuring: const { a, b } = ... or const [ x, y ] = ...
	if (current(state).kind === TokenKind.LBrace) {
		const pattern = try parseObjectPattern(state);
		// Optional type annotation
		if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
			advance(state);
			skipTypeAnnotation(state);
		}
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
		// Optional type annotation
		if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
			advance(state);
			skipTypeAnnotation(state);
		}
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
	if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
		advance(state);
		skipTypeAnnotation(state);
	}

	if (current(state).kind !== TokenKind.Assign) {
		return Result.err(`Expected '=' in variable declaration at line ${current(state).line.toString()}`);
	}

	advance(state);
	const init = try callExprParser(state);
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.VariableDecl, {
		declName: nameToken.value,
		initializer: init,
		isConst: keyword.kind === TokenKind.Const,
	}, keyword));
}

// ===== Specifier List Helper =====
// Parses { name, name as alias, ... } — shared by import and re-export

function parseSpecifierList(state: ParserState, names: string[], aliases: string[]): void {
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
}

// ===== Function Declaration =====
// function name(a: T, b: U): R { ... }

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
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected function name at line ${nameToken.line.toString()}`);
	}

	advance(state);
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after function name at line ${current(state).line.toString()}`);
	}

	const params = parseParamList(state);
	// Optional return type annotation: function f(): string { ... }
	if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
		advance(state);
		skipTypeAnnotation(state);
	}

	return Result.ok(createNode(NodeKind.FunctionDecl, {
		fnName: nameToken.value,
		params,
		fnBody: try callBlockParser(state),
		fnFlags: flags,
	}, fnToken));
}

// ===== Import Declaration =====
// import { A, B as C } from "module";

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
	parseSpecifierList(state, names, aliases);

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
// export function/const/let/enum/interface/type ...

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
		parseSpecifierList(state, names, aliases);
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

	return Result.err(`Expected declaration after 'export' at line ${current(state).line.toString()}`);
}

// ===== Type Alias Declaration =====
// type X = SomeType;

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
	skipTypeAnnotation(state);
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.TypeAliasDecl, {
		aliasName: nameToken.value,
	}, typeToken));
}

// ===== Enum Declaration =====
// enum X { A, B, C }

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
// interface X { field: Type; method(): void; }

export function parseInterfaceDecl(state: ParserState): NodeResult {
	const ifaceToken = current(state);

	advance(state);
	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected identifier after 'interface' at line ${nameToken.line.toString()}`);
	}

	advance(state);
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

		// Colon + type annotation
		if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
			advance(state);
			skipTypeAnnotation(state);
		}

		// Skip semicolons and commas between members
		if (!isAtEnd(state) && (current(state).kind === TokenKind.Semicolon || current(state).kind === TokenKind.Comma)) {
			advance(state);
		}
	}

	if (current(state).kind !== TokenKind.RBrace) {
		return Result.err(`Expected '}' after interface body at line ${current(state).line.toString()}`);
	}

	advance(state);
	return Result.ok(createNode(NodeKind.InterfaceDecl, {
		interfaceName: nameToken.value,
		interfaceFields: fields,
	}, ifaceToken));
}

// ===== Class Declaration =====
// [abstract] class Name [extends Base] { members... }

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

	// Optional generic type parameters: class Foo<T> — skip
	skipGenericParams(state);

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

	return Result.ok(createNode(NodeKind.ClassDecl, {
		className: nameToken.value,
		classExtends: extendsName,
		classBody: members,
	}, classToken));
}

function parseClassMember(state: ParserState): NodeResult {
	const memberToken = current(state);

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

	// Property — no try, skip initializer tokens manually
	if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
		advance(state);
		skipTypeAnnotation(state);
	}
	if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
		advance(state);
		skipDefaultValue(state);
	}
	consumeSemicolon(state);

	return Result.ok(createNode(NodeKind.PropertyDecl, {
		propName: nameToken.value,
		propIsStatic: memberIsStatic,
	}, nameToken));
}

// parseParamList and skipDefaultValue imported from ../util


function parseClassConstructor(state: ParserState): NodeResult {
	const ctorToken = current(state);
	advance(state);
	const params = parseParamList(state);
	const body = try callBlockParser(state);
	return Result.ok(createNode(NodeKind.ConstructorDecl, {
		ctorParams: params,
		ctorBody: body,
	}, ctorToken));
}

function parseClassAccessor(state: ParserState, isStatic: boolean, flags: string): NodeResult {
	const accToken = current(state);
	const accKind = current(state).value;
	advance(state);
	const accName = current(state).value;
	advance(state);
	const params = parseParamList(state);
	const body = try callBlockParser(state);
	return Result.ok(createNode(NodeKind.MethodDecl, {
		methodName: accKind + "_" + accName,
		methodParams: params,
		methodBody: body,
		methodIsStatic: isStatic,
		methodFlags: flags,
	}, accToken));
}

function parseClassMethodBody(state: ParserState, nameToken: Token, isStatic: boolean, flags: string): NodeResult {
	const params = parseParamList(state);
	// Optional return type
	if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
		advance(state);
		skipTypeAnnotation(state);
	}
	// Abstract methods have no body — just semicolon
	if (current(state).kind === TokenKind.Semicolon) {
		consumeSemicolon(state);
		return Result.ok(createNode(NodeKind.MethodDecl, {
			methodName: nameToken.value,
			methodParams: params,
			methodBody: createNode(NodeKind.BlockStmt, { statements: [] }, nameToken),
			methodIsStatic: isStatic,
			methodFlags: flags,
		}, nameToken));
	}
	const body = try callBlockParser(state);
	return Result.ok(createNode(NodeKind.MethodDecl, {
		methodName: nameToken.value,
		methodParams: params,
		methodBody: body,
		methodIsStatic: isStatic,
		methodFlags: flags,
	}, nameToken));
}

// ===== Destructuring Patterns =====

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
// @name or @name(args)

export function parseMacroInvocation(state: ParserState): NodeResult {
	const atToken = current(state);
	advance(state); // consume '@'
	const nameToken = current(state);
	// Accept identifiers and keywords as macro names (e.g., @export, @inline)
	const macroName = nameToken.value;
	advance(state);

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
});

testGroup("Async/Generator Decl", () => {
	test("async function", () => { check(programOk("async function f() {}")); });
	test("generator function", () => { check(programOk("function* gen() { yield 1; }")); });
	test("async generator", () => { check(programOk("async function* both() { yield 1; }")); });
	test("export async", () => { check(programOk("export async function f() {}")); });
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
});
