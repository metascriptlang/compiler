import { Node, NodeKind, CallExprData, StringLiteralData, SymbolKind, Type } from "../ast/node";
import { CheckerContext, addError } from "./context";
import { createPromise, createModuleNamespace, createFunction, errorType } from "./types";
import { makeSymbol } from "./symbol";
import { callCheckExpr } from "./checkerCallbacks";
import { resolveImportSourcePath } from "./collectPass";

export const DYNAMIC_IMPORT = "DynamicImport";

function refuse(ctx: CheckerContext, at: Node, message: string): Type {
	addError(ctx, message, at.location.line, at.location.column);
	return errorType();
}

export function checkImportCall(ctx: CheckerContext, node: Node): Type {
	const d = node.data as CallExprData;
	for (const arg of d.arguments) callCheckExpr(ctx, arg, null);
	if (d.arguments.length == 0 || d.arguments.length > 2) {
		return refuse(ctx, node, "import() takes one module specifier: import(\"./module\")");
	}
	if (d.arguments.length == 2) {
		return refuse(ctx, d.arguments[1], "import attributes are not supported: write import(\"./module\") with the specifier alone");
	}
	const specifier = d.arguments[0];
	if (specifier.kind != NodeKind.StringLiteral) {
		return refuse(ctx, specifier, "the specifier of import() must be a string literal, so the compiler knows which module to build; a computed specifier is not supported");
	}
	if (ctx.targetOs == "solana" || ctx.targetOs == "bare") {
		return refuse(ctx, node, `import() is not supported on the ${ctx.targetOs} target: it has no event loop to initialize a module later`);
	}
	if (ctx.appMode == "lib" || ctx.appMode == "staticlib") {
		return refuse(ctx, node, `import() is not supported with --app=${ctx.appMode}: the host runs the module initializers itself`);
	}
	const text = (specifier.data as StringLiteralData).value;
	const modulePath = resolveImportSourcePath(ctx, text);
	if (modulePath == "") return refuse(ctx, specifier, `Cannot resolve module '${text}'`);
	const promise = createPromise(createModuleNamespace(modulePath));
	const sym = makeSymbol("import", SymbolKind.Function, createFunction([], [], promise), false);
	sym.builtinKind = DYNAMIC_IMPORT;
	sym.modulePath = modulePath;
	d.callee.resolvedSym = sym;
	d.callee.nodeType = sym.symbolType;
	node.nodeType = promise;
	return promise;
}
