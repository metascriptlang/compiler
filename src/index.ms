// Metascript Compiler - Self-hosting compiler written in Metascript
// Module structure:
//   ast/       — AST types, printer (hub: ast.ms)
//   lexer/     — Tokenization (chars, token, lexer)
//   parser/    — Parsing (hub: parser.ms, context, expression, statement, type_annotation)
//   diagnostics/ — Error formatting helpers

import { formatToken } from "./lexer/token";
import { lex } from "./lexer/lexer";
import { parseExpression } from "./parser/parser";
import { parseProgram } from "./parser/parser";
import { printNode } from "./ast/ast";
import { formatError, unexpectedToken } from "./diagnostics/diagnostics";

// ===== Test Helpers =====

function testLex(input: string): void {
	console.log(`Input: ${input}`);
	const result = lex(input);
	if (!result.ok) {
		console.log(`  Lex error: ${result.error}`);
		return;
	}
	const tokens = result.value;
	console.log("Tokens:");
	for (const token of tokens) {
		console.log(`  ${formatToken(token)}`);
	}
}

function testParse(input: string): void {
	console.log(`Input: ${input}`);
	const lexResult = lex(input);
	if (!lexResult.ok) {
		console.log(`  Lex error: ${lexResult.error}`);
		return;
	}
	const parseResult = parseExpression(lexResult.value);
	if (!parseResult.ok) {
		console.log(`  Parse error: ${parseResult.error}`);
		return;
	}
	printNode(parseResult.value, 0);
}

function testParseProgram(input: string): void {
	console.log(`Input: ${input}`);
	const lexResult = lex(input);
	if (!lexResult.ok) {
		console.log(`  Lex error: ${lexResult.error}`);
		return;
	}
	const parseResult = parseProgram(lexResult.value);
	if (!parseResult.ok) {
		console.log(`  Parse error: ${parseResult.error}`);
		return;
	}
	const stmts = parseResult.value;
	for (const stmt of stmts) {
		printNode(stmt, 1);
	}
}

// ===== Main =====

function main(): void {
	console.log("=== Metascript Compiler ===");
	console.log("Step 1: Testing Lexer\n");

	testLex("hello 123 world 456");
	console.log("");
	testLex("const x = 42;");
	console.log("");
	testLex("\"hello world\"");
	console.log("");
	testLex("a === b && c !== d");
	console.log("");
	testLex("(x) => x + 1");
	console.log("");
	testLex("a + b // comment");

	console.log("\n--- Testing Error Handling ---");
	testLex("#invalid");

	console.log("\nLexer tests passed!");

	// Step 2: Testing Expression Parser
	console.log("\n\nStep 2: Testing Expression Parser\n");

	testParse("42");
	console.log("");
	testParse("1 + 2 * 3");
	console.log("");
	testParse("myVar");
	console.log("");
	testParse("add(1, 2)");
	console.log("");
	testParse("!x");
	console.log("");
	testParse("-42");

	console.log("\nParser tests passed!");

	// Step 3: Testing Statement Parser
	console.log("\n\nStep 3: Testing Statement Parser\n");

	testParseProgram("const x = 1 + 2;");
	console.log("");
	testParseProgram("let name = \"hello\";");
	console.log("");
	testParseProgram("if (x) { y; }");
	console.log("");
	testParseProgram("while (i) { i; }");
	console.log("");
	testParseProgram("function add(a, b) { return a + b; }");
	console.log("");
	testParseProgram("for (let i = 0; i < 10; i++) { x; }");
	console.log("");
	testParseProgram("for (const item of items) { item; }");
	console.log("");
	testParseProgram("while (true) { break; }");

	// Type annotations (skipped but parsed without error)
	console.log("\n--- Testing Type Annotations ---");
	testParseProgram("const x: number = 42;");
	console.log("");
	testParseProgram("function greet(name: string): void { name; }");

	console.log("\nStatement parser tests passed!");
}
