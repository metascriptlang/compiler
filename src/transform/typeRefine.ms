// Type Refiner — Deep Decorator: bottom-up type stamping for the full AST
//
// After transforms create synthetic AST nodes and the cross-module checker
// resolves real types, many expression nodes still have nodeType === null.
// This pass walks bottom-up, stamping types on:
//   1. Identifiers — from resolvedSym (primary) or scope map (fallback)
//   2. CallExpr — return type from callee's Function type
//   3. MemberExpr — field type from object's type
//   4. ArrayAccess — element type from array's type
//   5. VariableDecl — propagate from initializer when decl is untyped
//
// The bottom-up order means children are typed before parents, so
// parse(state).value.kind resolves as a chain: CallExpr → MemberExpr → MemberExpr.
//
// Pipeline position: after evaluateComptimeBlocks, before transformForNative.

import {
	Node, NodeKind,
	IdentifierData, VariableDeclData, FunctionDeclData,
	MemberExprData, ArrayAccessData, BlockStmtData,
	CallExprData,
} from "../ast/node";
import { Type, TypeKind, numberType, booleanType, stringType } from "../checker/types";
// Registry accessed via ctx.checkerCtx.exportRegistry (no extra import needed)
import { TransformContext } from "./context";
import { mapChildren } from "./walker";

// ===== Scope Stack =====
// Parallel arrays per scope level (MetaScript has no Map built-in).

interface TypeScope {
	names: string[];
	types: Type[];
}

function createScope(): TypeScope {
	return { names: [], types: [] };
}

function scopeLookup(scopes: TypeScope[], name: string): Type {
	let i = scopes.length - 1;
	while (i >= 0) {
		const s = scopes[i];
		let j = s.names.length - 1;
		while (j >= 0) {
			if (s.names[j] === name) return s.types[j];
			j = j - 1;
		}
		i = i - 1;
	}
	return null as unknown as Type;
}

function scopeRecord(scopes: TypeScope[], name: string, t: Type): void {
	const top = scopes[scopes.length - 1];
	top.names.push(name);
	top.types.push(t);
}

// ===== Type Re-derivation =====
// Mirrors makeMember (util.ms) and makeArrayAccess (util.ms).

function rederiveMemberType(node: Node): void {
	const d = node.data as MemberExprData;
	if (d.object === null) return;
	if (d.object.nodeType === null) return;

	const ot = d.object.nodeType;
	const prop = d.property;

	if ((ot.kind === TypeKind.Array || ot.kind === TypeKind.String) && prop === "length") {
		node.nodeType = numberType();
	} else if (ot.kind === TypeKind.Result) {
		if (prop === "ok") { node.nodeType = booleanType(); }
		else if (prop === "value" && ot.typeReturn !== null) { node.nodeType = ot.typeReturn; }
		else if (prop === "error" && ot.typeExtra !== null) { node.nodeType = ot.typeExtra; }
	} else if (ot.kind === TypeKind.Object) {
		let pi = 0;
		while (pi < ot.typeNames.length) {
			if (ot.typeNames[pi] === prop) {
				if (pi < ot.typeChildren.length) {
					node.nodeType = ot.typeChildren[pi];
				}
				pi = ot.typeNames.length;  // break
			}
			pi = pi + 1;
		}
	} else if (ot.kind === TypeKind.SizedArray && prop === "length") {
		node.nodeType = numberType();
	} else if (ot.kind === TypeKind.Span && prop === "length") {
		node.nodeType = numberType();
	}
}

function rederiveArrayAccessType(node: Node): void {
	const d = node.data as ArrayAccessData;
	if (d.array === null) return;
	if (d.array.nodeType === null) return;

	const at = d.array.nodeType;
	if ((at.kind === TypeKind.Array || at.kind === TypeKind.SizedArray || at.kind === TypeKind.Span) && at.typeReturn !== null) {
		node.nodeType = at.typeReturn;
	} else if (at.kind === TypeKind.String) {
		node.nodeType = numberType();  // string indexing returns char code
	}
}

// Derive CallExpr return type from callee's function type
function deriveCallReturnType(node: Node): void {
	const d = node.data as CallExprData;
	if (d.callee === null) return;

	// Source 1: callee's nodeType (already stamped bottom-up)
	if (d.callee.nodeType !== null && d.callee.nodeType.kind === TypeKind.Function) {
		if (d.callee.nodeType.typeReturn !== null) {
			node.nodeType = d.callee.nodeType.typeReturn;
		}
		return;
	}

	// Source 2: CallExpr's own resolvedSym (set by checker for direct calls)
	if (node.resolvedSym !== null && node.resolvedSym.symbolType !== null) {
		const symType = node.resolvedSym.symbolType;
		if (symType.kind === TypeKind.Function && symType.typeReturn !== null) {
			node.nodeType = symType.typeReturn;
		}
	}
}

// ===== Main Refiner =====

// Registry entries stored as duck-typed array to avoid circular imports
interface RegistrySymbol {
	name: string;
	symType: Type;
}
interface RegistryEntry {
	symbols: RegistrySymbol[];
}
interface RegistryWrapper {
	entries: RegistryEntry[];
}
let _registryEntries: RegistryEntry[] = null as unknown as RegistryEntry[];

export function refineTypes(program: Node, ctx: TransformContext, registry: Node): Node {
	if (registry !== null) {
		const r = registry as unknown as RegistryWrapper;
		_registryEntries = r.entries;
	} else {
		_registryEntries = null as unknown as RegistryEntry[];
	}
	const scopes: TypeScope[] = [];
	scopes.push(createScope());

	refineNode(program, scopes);
	_registryEntries = null as unknown as RegistryEntry[];
	return program;
}

// Registry Bridge: look up cross-module symbol by name
function registryLookup(name: string): Type {
	if (_registryEntries === null) return null as unknown as Type;
	let ei = 0;
	while (ei < _registryEntries.length) {
		const entry = _registryEntries[ei];
		let si = 0;
		while (si < entry.symbols.length) {
			const sym = entry.symbols[si];
			if (sym.name === name) return sym.symType;
			si = si + 1;
		}
		ei = ei + 1;
	}
	return null as unknown as Type;
}

function refineNode(node: Node, scopes: TypeScope[]): void {
	if (node === null) return;

	// Pre-order: handle scope-creating nodes before recursing children
	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		// Record function name in enclosing scope (for recursive calls and references)
		if (node.nodeType !== null && fd.fnName.length > 0) {
			scopeRecord(scopes, fd.fnName, node.nodeType);
		}
		scopes.push(createScope());
		seedFunctionParams(node, scopes);
		mapChildren(node, (child: Node): Node => {
			refineNode(child, scopes);
			return child;
		});
		scopes.pop();
		return;
	}

	if (node.kind === NodeKind.BlockStmt) {
		scopes.push(createScope());
		mapChildren(node, (child: Node): Node => {
			refineNode(child, scopes);
			return child;
		});
		scopes.pop();
		return;
	}

	// Recurse children first (bottom-up for type propagation)
	mapChildren(node, (child: Node): Node => {
		refineNode(child, scopes);
		return child;
	});

	// Post-order: stamp types after children are processed

	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (node.nodeType !== null) {
			scopeRecord(scopes, d.declName, node.nodeType);
		} else if (d.initializer !== null && d.initializer.nodeType !== null) {
			// Propagate initializer type up to the declaration
			node.nodeType = d.initializer.nodeType;
			scopeRecord(scopes, d.declName, d.initializer.nodeType);
		}
	} else if (node.kind === NodeKind.Identifier) {
		if (node.nodeType === null) {
			// 3-tier lookup: resolvedSym → local scope → global registry
			if (node.resolvedSym !== null && node.resolvedSym.symbolType !== null) {
				node.nodeType = node.resolvedSym.symbolType;
			} else {
				const id = node.data as IdentifierData;
				const found = scopeLookup(scopes, id.name);
				if (found !== null) {
					node.nodeType = found;
				} else {
					// Registry Bridge: cross-module symbol lookup
					const regType = registryLookup(id.name);
					if (regType !== null) {
						node.nodeType = regType;
					}
				}
			}
		}
	} else if (node.kind === NodeKind.CallExpr) {
		if (node.nodeType === null) {
			deriveCallReturnType(node);
		}
	} else if (node.kind === NodeKind.MemberExpr) {
		if (node.nodeType === null) {
			rederiveMemberType(node);
		}
	} else if (node.kind === NodeKind.ArrayAccess) {
		if (node.nodeType === null) {
			rederiveArrayAccessType(node);
		}
	}
}

// Seed scope with function parameter types from FunctionDecl.nodeType
function seedFunctionParams(fnNode: Node, scopes: TypeScope[]): void {
	if (fnNode.nodeType === null) return;
	const fnType = fnNode.nodeType;
	if (fnType.kind !== TypeKind.Function) return;

	const d = fnNode.data as FunctionDeclData;
	const paramNames = d.fnParams;
	const paramTypes = fnType.typeChildren;
	if (paramNames === null || paramTypes === null) return;

	let i = 0;
	while (i < paramNames.length && i < paramTypes.length) {
		if (paramTypes[i] !== null) {
			scopeRecord(scopes, paramNames[i], paramTypes[i]);
		}
		i = i + 1;
	}
}

// ===== Tests =====
import { check } from "std/testing";
