// Test: type alias struct field resolution with union variant disambiguation
// Bug: findUnionVariant matched by field name only, picking { value: number }
// instead of { value: string } when both variants have a "value" field.

import { checkSource } from "./helpers";
import { hasErrors } from "../../checker/context";
import { createMapProvider, loadModuleGraph, canonicalModulePath, MapEntry } from "../../module/loader";
import { checkModuleGraph, getPreludeContext } from "../../checker/orchestrator";
import { findModule } from "../../module/graph";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry } from "../../checker/checkPass";

test "as-cast to type alias with overlapping union field names" {
	// Simulates the exact pattern from self-compilation:
	// NodeData = | { value: number } | { value: string } | ...
	// StringLiteralData = { value: string }
	// (node.data as StringLiteralData).value should be string, not number
	const ctx = checkSource("type NodeData = | { value: number } | { value: string };\ntype StringLiteralData = { value: string };\ntype NumberLiteralData = { value: number };\nfunction processStr(data: NodeData): string {\n\tconst sd = data as StringLiteralData;\n\treturn sd.value;\n}\nfunction processNum(data: NodeData): number {\n\tconst nd = data as NumberLiteralData;\n\treturn nd.value;\n}");
	assert ctx !== null;
	if (ctx.errors.length > 0) {
		for (const e of ctx.errors) {
			console.log("UNION-OVERLAP-ERR: " + e);
		}
	}
	assert !hasErrors(ctx);
}

test "cross-module as-cast with overlapping union fields" {
	const modA = "node.ms";
	const modB = "checker.ms";
	const srcA = "export type NodeData = | { value: number } | { value: string } | { name: string };\nexport type NumberLiteralData = { value: number };\nexport type StringLiteralData = { value: string };\nexport type IdentifierData = { name: string };";
	const srcB = "import { NodeData, StringLiteralData, NumberLiteralData } from \"./node\";\nfunction useStr(data: NodeData): string {\n\tconst sd = data as StringLiteralData;\n\treturn sd.value;\n}\nfunction useNum(data: NodeData): number {\n\tconst nd = data as NumberLiteralData;\n\treturn nd.value;\n}";
	const entries: MapEntry[] = [
		{ entryPath: modA, entrySource: srcA },
		{ entryPath: modB, entrySource: srcB },
	];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(modB, provider);
	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();
	const mod = findModule(graph, canonicalModulePath(modB));
	assert mod !== null;
	const pr = parseSource(mod.source);
	assert pr.ok;
	const ctx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
	assert ctx !== null;
	if (ctx.errors.length > 0) {
		for (const e of ctx.errors) {
			console.log("CROSS-OVERLAP-ERR: " + e);
		}
	}
	assert !hasErrors(ctx);
}
