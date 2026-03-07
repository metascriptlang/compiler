// Printer — transforms MetaScript AST → Doc IR
// Implementation logic follows Biome/Prettier standards (2026).

import { Node, NodeKind } from "../../../ast/node";
import { FormatOptions } from "../options";
import {
	Doc, docNil, docText, docGroup, docHardLine, docLineSuffix,
} from "../doc";
import { registerNodePrinter } from "./callbacks";

import {
	printNumberLiteral, printStringLiteral, printBooleanLiteral, printIdentifier,
} from "./literals";
import {
	printBinaryExpr, printUnaryExpr, printUpdateExpr, printCallExpr,
	printMemberExpr, printArrayAccess, printObjectLiteral, printArrayLiteral,
	printArrowFunction, printConditionalExpr, printSpreadExpr, printNewExpr,
	printTypeAssertion, printMatchExpr,
} from "./expressions";
import {
	printProgram, printBlock, printVariableDecl, printExprStmt,
	printReturnStmt, printIfStmt, printWhileStmt, printForStmt,
	printForOfStmt, printDoWhileStmt, printSwitchStmt, printMatchStmt,
	printFunctionDecl, printThrowStmt, printTryCatchStmt, printDeferStmt,
	printBreakStmt, printContinueStmt,
} from "./statements";
import {
	printImportDecl, printExportDecl, printTypeAliasDecl, printEnumDecl,
	printInterfaceDecl, printClassDecl, printExternDecl, printDecoratedDecl,
	printTestDecl, printPropertyDecl, printMethodDecl,
} from "./declarations";

export function printNode(node: Node, options: FormatOptions): Doc {
	if (node === null) return docNil();

	const innerDoc = match (node.kind) {
		// ===== Literals =====
		NodeKind.NumberLiteral => printNumberLiteral(node),
		NodeKind.StringLiteral => printStringLiteral(node, options),
		NodeKind.BooleanLiteral => printBooleanLiteral(node),
		NodeKind.NullLiteral => docText("null"),
		NodeKind.Identifier => printIdentifier(node),

		// ===== Expressions =====
		NodeKind.BinaryExpr => printBinaryExpr(node, options),
		NodeKind.UnaryExpr => printUnaryExpr(node, options),
		NodeKind.UpdateExpr => printUpdateExpr(node, options),
		NodeKind.CallExpr => printCallExpr(node, options),
		NodeKind.MemberExpr => printMemberExpr(node, options),
		NodeKind.ArrayAccess => printArrayAccess(node, options),
		NodeKind.ObjectLiteral => printObjectLiteral(node, options),
		NodeKind.ArrayLiteral => printArrayLiteral(node, options),
		NodeKind.ArrowFunction => printArrowFunction(node, options),
		NodeKind.ConditionalExpr => printConditionalExpr(node, options),
		NodeKind.SpreadExpr => printSpreadExpr(node, options),
		NodeKind.NewExpr => printNewExpr(node, options),
		NodeKind.TypeAssertion => printTypeAssertion(node, options),
		NodeKind.MatchExpr => printMatchExpr(node, options),

		// ===== Statements =====
		NodeKind.Program => printProgram(node, options),
		NodeKind.BlockStmt => printBlock(node, options),
		NodeKind.VariableDecl => printVariableDecl(node, options),
		NodeKind.ExprStmt => printExprStmt(node, options),
		NodeKind.ReturnStmt => printReturnStmt(node, options),
		NodeKind.IfStmt => printIfStmt(node, options),
		NodeKind.WhileStmt => printWhileStmt(node, options),
		NodeKind.ForStmt => printForStmt(node, options),
		NodeKind.ForOfStmt => printForOfStmt(node, options),
		NodeKind.DoWhileStmt => printDoWhileStmt(node, options),
		NodeKind.SwitchStmt => printSwitchStmt(node, options),
		NodeKind.MatchStmt => printMatchStmt(node, options),
		NodeKind.FunctionDecl => printFunctionDecl(node, options),
		NodeKind.ThrowStmt => printThrowStmt(node, options),
		NodeKind.TryCatchStmt => printTryCatchStmt(node, options),
		NodeKind.DeferStmt => printDeferStmt(node, options),
		NodeKind.BreakStmt => printBreakStmt(node),
		NodeKind.ContinueStmt => printContinueStmt(node),

		// ===== Declarations =====
		NodeKind.ImportDecl => printImportDecl(node, options),
		NodeKind.ExportDecl => printExportDecl(node, options),
		NodeKind.TypeAliasDecl => printTypeAliasDecl(node, options),
		NodeKind.EnumDecl => printEnumDecl(node, options),
		NodeKind.InterfaceDecl => printInterfaceDecl(node, options),
		NodeKind.ClassDecl => printClassDecl(node, options),
		NodeKind.ExternDecl => printExternDecl(node, options),
		NodeKind.DecoratedDecl => printDecoratedDecl(node, options),
		NodeKind.TestDecl => printTestDecl(node, options),
		NodeKind.PropertyDecl => printPropertyDecl(node, options),
		NodeKind.MethodDecl => printMethodDecl(node, options),

		_ => docText("<unsupported node: " + node.kind.toString() + ">"),
	};

	// Wrap with comments if present
	if (node.comments.length > 0) {
		const leading: Doc[] = [];
		const trailing: Doc[] = [];
		for (const comment of node.comments) {
			if (comment.line === node.location.line) {
				// Same line as node — trailing comment
				trailing.push(docLineSuffix([docText(" " + comment.value)]));
			} else {
				// Different line — leading comment
				leading.push(docText(comment.value));
				leading.push(docHardLine());
			}
		}
		if (leading.length > 0 || trailing.length > 0) {
			const parts: Doc[] = [];
			for (const l of leading) { parts.push(l); }
			parts.push(innerDoc);
			for (const t of trailing) { parts.push(t); }
			return docGroup(parts);
		}
	}

	return innerDoc;
}

// Automatically register on module load
registerNodePrinter(printNode);
