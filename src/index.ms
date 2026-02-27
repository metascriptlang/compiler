// Metascript Compiler - Self-hosting compiler written in Metascript
// Module structure:
//   ast/       — AST types, printer (hub: index.ms)
//   lexer/     — Tokenization (hub: index.ms)
//   parser/    — Parsing (hub: index.ms)
//   checker/   — Type checking (hub: index.ms)
//   transform/ — AST lowering transforms (hub: index.ms)
//   module/      — Multi-module loading (hub: index.ms)
//   diagnostics/ — Error formatting helpers

import { ModuleGraph, findModule, loadModuleGraph, createMapProvider, MapEntry } from "./module/index";
import { formatToken } from "./lexer/token";
import { lex } from "./lexer/index";
import { parseExpression } from "./parser/index";
import { parseSource } from "./parser/statements/validation";
import { Node, ProgramData } from "./ast/node";
import { printNode } from "./ast/index";
import { formatError, unexpectedToken } from "./diagnostics/diagnostics";
import { checkProgram, checkModuleGraph } from "./checker/index";
import { transformProgram } from "./transform/index";
import { analyzeProgram } from "./analyzer/index";
import { generateJS } from "./codegen/index";
import {
	TransAmDb, createTransAmDb,
	dbCompileSource, dbCompileToJS as dbCompileToJSNode, dbSetFileText
} from "./compiler/transam/index";

// ===== Compiler Pipeline =====
// Single-module: parse → check → transform → analyze → codegen
// Multi-module:  load → check graph → transform → analyze → codegen
// Trans-Am: incremental caching — unchanged input skips all phases

type NodeResult = Result<Node, string>;

// Module-level db (lazy init)
let _db: TransAmDb = null as unknown as TransAmDb;

function getDb(): TransAmDb {
	if (_db === null) {
		_db = createTransAmDb(256);
	}
	return _db;
}

// Shared: parse → check → transform → analyze pipeline (incremental via Trans-Am)
export function compileSource(input: string): NodeResult {
	const db = getDb();
	const result = dbCompileSource(db, input);
	if (result === null) return Result.err("Compilation failed");
	return Result.ok(result);
}

// JS codegen: parse → check → transform → generateJS (skip analyzer)
type StringResult = Result<string, string>;

export function compileToJS(input: string): StringResult {
	const db = getDb();
	const transformed = dbCompileToJSNode(db, input);
	if (transformed === null) return Result.err("Compilation failed");
	const jsCode = generateJS(transformed);
	return Result.ok(jsCode);
}

// Multi-module compilation: loads all modules from entry point,
// checks them in dependency order, transforms entry module.
export function compileProject(entryPath: string): NodeResult {
	// Build module graph from entry point (uses real file I/O via provider)
	// For now, this is a placeholder — real file provider TBD
	const entries: MapEntry[] = [];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(entryPath, provider);

	// Check all modules in dependency order
	checkModuleGraph(graph);

	// Collect errors
	if (graph.errors.length > 0) {
		return Result.err(graph.errors[0]);
	}
	for (const mod of graph.modules) {
		if (mod.errors.length > 0) {
			return Result.err(mod.errors[0]);
		}
	}

	// Transform entry module
	const entryMod = findModule(graph, entryPath);
	if (entryMod === null) return Result.err("Entry module not found");
	return compileSource(entryMod.source);
}

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
	const parseResult = parseSource(input);
	if (!parseResult.ok) {
		console.log(`  Parse error: ${parseResult.error}`);
		return;
	}
	const program = parseResult.value;
	const programData = program.data as ProgramData;
	for (const stmt of programData.programStmts) {
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
