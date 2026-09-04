// Monomorphization — generic type instance emission
//
// Function monomorphization is handled entirely by on-demand instantiation
// during type checking (src/checker/instantiate.ms → callInstantiateGeneric).
// This file only handles generic TYPE instances (e.g., Box<number> → InterfaceDecl).

import { Node, NodeKind, NodeData, makeLoc, ProgramData, createNodeAt } from "../ast/node";
import { CheckerContext } from "../checker/context";
import {
	getGenericTypeInstCount, getGenericTypeInstMangledName,
	getGenericTypeInstFieldCount, getGenericTypeInstFieldNameAt,
	getGenericTypeInstFieldTypeAt, resetGenericTypeInsts,
} from "../parser/context";

// ===== Generic Type Instance → InterfaceDecl Nodes =====
// Standard-aligned: monomorphize creates concrete InterfaceDecl nodes so codegen
// is fully generic-unaware. Reads from GenericTypeInstStore (populated by checker).

function monoEmitOneTypeInst(program: Node, idx: int32): void {
	const mangledName = getGenericTypeInstMangledName(idx);
	const fieldCount = getGenericTypeInstFieldCount(idx);
	const fieldNames: string[] = [];
	const fieldTypes: string[] = [];
	for (let fi = 0; fi < fieldCount; fi += 1) {
		fieldNames.push(getGenericTypeInstFieldNameAt(idx, fi));
		fieldTypes.push(getGenericTypeInstFieldTypeAt(idx, fi));
	}
	const loc = makeLoc(0, 0);
	const data: NodeData = { interfaceName: mangledName, interfaceFields: fieldNames, interfaceFieldTypes: fieldTypes, interfaceExtends: [] as string[], nameLocation: loc };
	const declNode = createNodeAt(NodeKind.InterfaceDecl, data, loc);
	const pd = program.data as ProgramData;
	pd.programStmts.push(declNode);
}

function monoEmitTypeInstNodes(program: Node): void {
	const count = getGenericTypeInstCount();
	for (let i = 0; i < count; i += 1) {
		monoEmitOneTypeInst(program, i);
	}
	resetGenericTypeInsts();
}

// ===== Public Entry Point =====

export function monomorphizeProgram(program: Node, checkerCtx: CheckerContext): Node {
	if (checkerCtx === null) return program;
	if (program === null) return program;
	if (program.kind !== NodeKind.Program) return program;

	// Create InterfaceDecl nodes for generic type instantiations
	// (independent of function monomorphization — Box<number> may exist without generic functions)
	// Class constructors are handled separately via on-demand instantiation in checkExprPass.
	monoEmitTypeInstNodes(program);

	return program;
}
