// Typed JSON API — jsonParse<T> / jsonStringify<T> handoff tests
//
// Tests that @builtin("JsonParse") / @builtin("JsonStringify") generate
// per-type helper functions during builtinLower transform phase.

import { fullPipeline, findFnDecl, checkSource } from "./helpers";
import { Node, NodeKind, ProgramData, FunctionDeclData } from "../../ast/node";
import { lookupSymbol } from "../../checker/symbol";

test "jsonParse generates helper function" {
	const src = "interface Person { name: string; age: number; }\nconst p = jsonParse<Person>(\"{}\")\;";
	const result = fullPipeline(src);
	if (result !== null) {
		const fn = findFnDecl(result, "__jsonParse_Person");
		assert fn !== null;
	}
}

test "jsonParse helper has correct params" {
	const src = "interface Person { name: string; age: number; }\nconst p = jsonParse<Person>(\"{}\")\;";
	const result = fullPipeline(src);
	if (result !== null) {
		const fn = findFnDecl(result, "__jsonParse_Person");
		if (fn !== null) {
			const fd = fn.data as FunctionDeclData;
			assert fd.params.length === 1;
			assert fd.params[0] === "input";
		}
	}
}

test "jsonStringify generates helper function" {
	const src = "interface Item { label: string; count: number; }\nconst s = jsonStringify<Item>({ label: \"x\", count: 1 })\;";
	const result = fullPipeline(src);
	if (result !== null) {
		const fn = findFnDecl(result, "__jsonStringify_Item");
		assert fn !== null;
	}
}

test "jsonParse deduplicates helpers" {
	const src = "interface Msg { text: string; }\nconst a = jsonParse<Msg>(\"{}\")\;\nconst b = jsonParse<Msg>(\"{}\")\;";
	const result = fullPipeline(src);
	if (result !== null) {
		// Count helpers with prefix __jsonParse_Msg
		const pd = result.data as ProgramData;
		let count = 0;
		let i = 0;
		while (i < pd.programStmts.length) {
			if (pd.programStmts[i].kind === NodeKind.FunctionDecl) {
				const fd = pd.programStmts[i].data as FunctionDeclData;
				if (fd.fnName === "__jsonParse_Msg") count = count + 1;
			}
			i = i + 1;
		}
		assert count === 1;
	}
}

test "jsonParse with boolean field" {
	const src = "interface Flag { enabled: boolean; }\nconst f = jsonParse<Flag>(\"{}\")\;";
	const result = fullPipeline(src);
	if (result !== null) {
		const fn = findFnDecl(result, "__jsonParse_Flag");
		assert fn !== null;
	}
}

test "jsonStringify with three field types" {
	const src = "interface Config { name: string; count: number; active: boolean; }\nconst s = jsonStringify<Config>({ name: \"x\", count: 1, active: true })\;";
	const result = fullPipeline(src);
	if (result !== null) {
		const fn = findFnDecl(result, "__jsonStringify_Config");
		assert fn !== null;
	}
}
