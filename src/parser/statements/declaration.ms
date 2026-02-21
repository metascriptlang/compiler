// Declaration Parsers - variable, function, import, export, type alias, enum, interface
// Uses callback injection via util.ms to avoid circular imports

import { Token, TokenKind } from "../../lexer/token";
import { Node, NodeKind, NodeData, createNode } from "../../ast/node";
import { ParserState, current, advance, isAtEnd } from "../context";
import { skipTypeAnnotation } from "../typeAnnotation";
import { callBlockParser, callExprParser, programOk } from "./util";
import { test, check, testGroup } from "std/testing";

type NodeResult = Result<Node, string>;

// ===== Variable Declaration =====
// const x = expr; | const x: Type = expr;

export function parseVariableDecl(state: ParserState): NodeResult {
	const keyword = current(state);
	advance(state);
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
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}

	return Result.ok(createNode(NodeKind.VariableDecl, {
		declName: nameToken.value,
		initializer: init,
		isConst: keyword.kind === TokenKind.Const,
	}, keyword));
}

// ===== Function Declaration =====
// function name(a: T, b: U): R { ... }

export function parseFunctionDecl(state: ParserState): NodeResult {
	const fnToken = current(state);
	advance(state);
	const nameToken = current(state);
	if (nameToken.kind !== TokenKind.Ident) {
		return Result.err(`Expected function name at line ${nameToken.line.toString()}`);
	}

	advance(state);
	if (current(state).kind !== TokenKind.LParen) {
		return Result.err(`Expected '(' after function name at line ${current(state).line.toString()}`);
	}

	advance(state);
	const params: string[] = [];
	while (!isAtEnd(state) && current(state).kind !== TokenKind.RParen) {
		const param = current(state);
		if (param.kind !== TokenKind.Ident) {
			return Result.err(`Expected parameter name at line ${param.line.toString()}`);
		}
		params.push(param.value);
		advance(state);

		// Optional param type annotation: (a: string, b: number)
		if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
			advance(state);
			skipTypeAnnotation(state);
		}

		if (current(state).kind === TokenKind.Comma) {
			advance(state);
		} else {
			break;
		}
	}

	if (current(state).kind !== TokenKind.RParen) {
		return Result.err(`Expected ')' after parameters at line ${current(state).line.toString()}`);
	}

	advance(state);
	// Optional return type annotation: function f(): string { ... }
	if (!isAtEnd(state) && current(state).kind === TokenKind.Colon) {
		advance(state);
		skipTypeAnnotation(state);
	}

	return Result.ok(createNode(NodeKind.FunctionDecl, {
		fnName: nameToken.value,
		params,
		fnBody: try callBlockParser(state),
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
		if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
			advance(state);
		}
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
		if (specifier.kind !== TokenKind.Ident) {
			return Result.err(`Expected identifier in import specifier at line ${specifier.line.toString()}`);
		}
		const importedName = specifier.value;
		advance(state);

		// Check for alias: X as Y
		if (!isAtEnd(state) && current(state).kind === TokenKind.As) {
			advance(state);
			const aliasToken = current(state);
			if (aliasToken.kind !== TokenKind.Ident) {
				return Result.err(`Expected identifier after 'as' at line ${aliasToken.line.toString()}`);
			}
			names.push(importedName);
			aliases.push(aliasToken.value);
			advance(state);
		} else {
			names.push(importedName);
			aliases.push(importedName);
		}

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
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}

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
		while (!isAtEnd(state) && current(state).kind !== TokenKind.RBrace) {
			const specifier = current(state);
			if (specifier.kind !== TokenKind.Ident) {
				return Result.err(`Expected identifier in export specifier at line ${specifier.line.toString()}`);
			}
			const exportedName = specifier.value;
			advance(state);
			if (!isAtEnd(state) && current(state).kind === TokenKind.As) {
				advance(state);
				aliases.push(current(state).value);
				advance(state);
			} else {
				aliases.push(exportedName);
			}
			names.push(exportedName);
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
		if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) { advance(state); }
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
	if (!isAtEnd(state) && current(state).kind === TokenKind.Semicolon) {
		advance(state);
	}

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
		// Optional value: A = 1 — skip value tokens without try (avoids DRC scope bug)
		if (!isAtEnd(state) && current(state).kind === TokenKind.Assign) {
			advance(state);
			while (!isAtEnd(state) && current(state).kind !== TokenKind.Comma && current(state).kind !== TokenKind.RBrace) {
				advance(state);
			}
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

// ===== Tests =====

testGroup("Stmt Variable Declarations", () => {
	test("const decl", () => { check(programOk("const x = 42;")); });
	test("let decl", () => { check(programOk("let y = 0;")); });
	test("string decl", () => { check(programOk("const s = \"hello\";")); });
	test("expr decl", () => { check(programOk("const a = 1 + 2 * 3;")); });
	test("call decl", () => { check(programOk("const x = f(a, b);")); });
	test("member decl", () => { check(programOk("const x = a.b.c;")); });
});

testGroup("Stmt Functions", () => {
	test("empty function", () => { check(programOk("function f() { }")); });
	test("single param", () => { check(programOk("function f(a) { return a; }")); });
	test("two params", () => { check(programOk("function add(a, b) { return a + b; }")); });
	test("three params", () => { check(programOk("function f(a, b, c) { return a; }")); });
	test("multi-statement body", () => { check(programOk("function f() { const x = 1; return x; }")); });
});

testGroup("Stmt Import Declarations", () => {
	test("single import", () => { check(programOk("import { Token } from \"./token\";")); });
	test("multi import", () => { check(programOk("import { Token, TokenKind } from \"./token\";")); });
	test("aliased import", () => { check(programOk("import { Token as T } from \"./token\";")); });
	test("mixed import", () => { check(programOk("import { Token, TokenKind as TK } from \"./token\";")); });
	test("three imports", () => { check(programOk("import { a, b, c } from \"./mod\";")); });
	test("side-effect import", () => { check(programOk("import \"./polyfill\";")); });
	test("import no semicolon", () => { check(programOk("import { x } from \"./y\"")); });
	test("std import", () => { check(programOk("import { test, check } from \"std/testing\";")); });
});

testGroup("Stmt Export Declarations", () => {
	test("export function", () => { check(programOk("export function f() { return 1; }")); });
	test("export const", () => { check(programOk("export const x = 42;")); });
	test("export let", () => { check(programOk("export let y = 0;")); });
	test("export enum", () => { check(programOk("export enum Color { Red, Green, Blue }")); });
	test("export interface", () => { check(programOk("export interface Point { x: number; y: number; }")); });
	test("export type", () => { check(programOk("export type ID = number;")); });
	test("re-export single", () => { check(programOk("export { Node } from \"./node\";")); });
	test("re-export multi", () => { check(programOk("export { Node, NodeKind, createNode } from \"./node\";")); });
	test("re-export aliased", () => { check(programOk("export { Token as T } from \"./token\";")); });
	test("re-export no semicolon", () => { check(programOk("export { x } from \"./y\"")); });
});

testGroup("Stmt Type Alias", () => {
	test("simple alias", () => { check(programOk("type ID = number;")); });
	test("generic alias", () => { check(programOk("type Result = Ok | Err;")); });
	test("array alias", () => { check(programOk("type Nodes = Node[];")); });
	test("generic type alias", () => { check(programOk("type NodeResult = Result<Node, string>;")); });
	test("function type alias", () => { check(programOk("type Handler = (a: string) => void;")); });
	test("leading pipe union", () => { check(programOk("type Data = | { x: number } | { y: string };")); });
	test("no semicolon", () => { check(programOk("type X = number")); });
});

testGroup("Stmt Enum Declarations", () => {
	test("simple enum", () => { check(programOk("enum Color { Red, Green, Blue }")); });
	test("single member", () => { check(programOk("enum Dir { Up }")); });
	test("trailing comma", () => { check(programOk("enum X { A, B, C, }")); });
	test("member with value", () => { check(programOk("enum Status { Active = 1, Inactive = 0 }")); });
	test("string values", () => { check(programOk("enum Kind { A = \"a\", B = \"b\" }")); });
	test("many members", () => { check(programOk("enum TK { A, B, C, D, E, F, G, H }")); });
});

testGroup("Stmt Interface Declarations", () => {
	test("simple interface", () => { check(programOk("interface Point { x: number; y: number; }")); });
	test("single field", () => { check(programOk("interface Named { name: string; }")); });
	test("optional field", () => { check(programOk("interface Opt { value?: number; }")); });
	test("generic field types", () => { check(programOk("interface Container { items: Array<number>; }")); });
	test("extends clause", () => { check(programOk("interface Dog extends Animal { breed: string; }")); });
	test("array field type", () => { check(programOk("interface State { tokens: Token[]; position: number; }")); });
});
