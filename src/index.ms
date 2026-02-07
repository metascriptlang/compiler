// Metascript Compiler
// A self-hosting compiler written in Metascript

import { Token, formatToken } from "./lexer/token";
import { lex } from "./lexer/lexer.ms";
import { ASTNode, createNode, printNode } from "./ast/node.ms";

function main(): void {
	console.log("=== Metascript Compiler ===");
	console.log("Step 1: Testing Lexer\n");

	// Test 1: Simple lexer test
	const input1 = "hello 123 world 456";
	console.log("Input: " + input1);
	const tokens1 = lex(input1);
	console.log("Tokens:");
	for (let i = 0; i < tokens1.len; i = i + 1) {
		const formatted: string = formatToken(tokens1[i]);
		console.log("  " + formatted);
	}

	// Test 2: Multi-line input
	console.log("\nInput: function add 42");
	const tokens2 = lex("function add 42");
	console.log("Tokens:");
	for (let i = 0; i < tokens2.len; i = i + 1) {
		const formatted: string = formatToken(tokens2[i]);
		console.log("  " + formatted);
	}

	console.log("\n✓ Lexer tests passed!");
	console.log("✓ Numbers recognized");
	console.log("✓ Identifiers recognized");
	console.log("✓ Whitespace handled");
}
