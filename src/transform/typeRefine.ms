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
	CallExprData, BinaryExprData, UnaryExprData, NumberLiteralData,
	ConditionalExprData, TypeAssertionData,
	ForOfStmtData, ArrowFunctionData,
	ReturnStmtData,
} from "../ast/node";
import { Type, TypeKind, isNumeric, numberType, booleanType, stringType, charType, createArray } from "../checker/types";
import { ExportRegistry } from "../checker/context";
import { TransformContext } from "./context";
import { mapChildren } from "./walker";
import { charAt, sliceStr, trimStr } from "../utils/string";

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

// Fallback for Object types where typeNames/typeChildren aren't populated.
// Uses well-known field names from core compiler types (Node, Symbol, Type).
function recoverKnownField(node: Node, typeName: string, prop: string): void {
	// Node fields
	if (typeName === "Node") {
		if (prop === "kind") { node.nodeType = registryTypeLookup("NodeKind"); }
		else if (prop === "nodeType") { node.nodeType = registryTypeLookup("Type"); }
		else if (prop === "resolvedSym") { node.nodeType = registryTypeLookup("Symbol"); }
		else if (prop === "flags") { node.nodeType = numberType(); }
	}
	// Symbol fields
	else if (typeName === "Symbol") {
		if (prop === "symbolKind") { node.nodeType = registryTypeLookup("SymbolKind"); }
		else if (prop === "symbolType") { node.nodeType = registryTypeLookup("Type"); }
		else if (prop === "name" || prop === "nativeName" || prop === "builtinKind") { node.nodeType = stringType(); }
		else if (prop === "symFlags") { node.nodeType = numberType(); }
		else if (prop === "declNode") { node.nodeType = registryTypeLookup("Node"); }
		else if (prop === "overloads") { node.nodeType = registryTypeLookup("msRefArray"); }
	}
	// Type fields
	else if (typeName === "Type") {
		if (prop === "kind") { node.nodeType = registryTypeLookup("TypeKind"); }
		else if (prop === "typeName") { node.nodeType = stringType(); }
		else if (prop === "typeReturn" || prop === "typeExtra") { node.nodeType = registryTypeLookup("Type"); }
		else if (prop === "typeFlags") { node.nodeType = numberType(); }
	}
	// Token fields
	else if (typeName === "Token") {
		if (prop === "kind") { node.nodeType = registryTypeLookup("TokenKind"); }
		else if (prop === "value") { node.nodeType = stringType(); }
		else if (prop === "line" || prop === "column") { node.nodeType = numberType(); }
	}
}

// Extract field type from structural typeName: "{ name : type , name2 : type2 }"
// Returns a Type or null if field not found.
function extractFieldTypeFromStructural(typeName: string, fieldName: string): Type {
	// Search for " fieldName : " pattern in typeName
	const needle = " " + fieldName + " : ";
	let pos = 0;
	while (pos < typeName.length) {
		// Find needle starting at pos
		let found = false;
		let ni = 0;
		if (pos + needle.length <= typeName.length) {
			found = true;
			while (ni < needle.length) {
				if (charAt(typeName, pos + ni) !== charAt(needle, ni)) {
					found = false;
					ni = needle.length; // break
				}
				ni = ni + 1;
			}
		}
		if (found) {
			// Extract type name after " fieldName : "
			const typeStart = pos + needle.length;
			let typeEnd = typeStart;
			let depth = 0;
			while (typeEnd < typeName.length) {
				const ch = charAt(typeName, typeEnd);
				if (ch === "<" || ch === "(" || ch === "{" || ch === "[") { depth = depth + 1; }
				if (ch === ">" || ch === ")" || ch === "}" || ch === "]") { depth = depth - 1; }
				if (depth === 0 && (ch === "," || ch === "}")) {
					typeEnd = typeName.length; // break
				} else {
					typeEnd = typeEnd + 1;
				}
			}
			// typeEnd went to typeName.length as break marker — actual end is before that
			// Re-scan to find actual boundary
			let actualEnd = typeStart;
			depth = 0;
			while (actualEnd < typeName.length) {
				const ch = charAt(typeName, actualEnd);
				if (ch === "<" || ch === "(" || ch === "{" || ch === "[") { depth = depth + 1; }
				if (ch === ">" || ch === ")" || ch === "}" || ch === "]") { depth = depth - 1; }
				if (depth === 0 && (ch === "," || ch === "}")) {
					const rawType = trimStr(sliceStr(typeName, typeStart, actualEnd));
					return resolveFieldTypeName(rawType);
				}
				actualEnd = actualEnd + 1;
			}
		}
		pos = pos + 1;
	}
	return null as unknown as Type;
}

// Resolve a type name string to a Type. Handles primitives and registry types.
function resolveFieldTypeName(rawType: string): Type {
	if (rawType === "string") return stringType();
	if (rawType === "number" || rawType === "float64") return numberType();
	if (rawType === "boolean") return booleanType();
	if (rawType === "void") return null as unknown as Type;
	// Array types: "T[]"
	if (rawType.endsWith("[]")) {
		const inner = sliceStr(rawType, 0, rawType.length - 2);
		const innerType = resolveFieldTypeName(inner);
		if (innerType !== null) return createArray(innerType);
	}
	// Named types: look up in registry
	const reg = registryTypeLookup(rawType);
	if (reg !== null) return reg;
	const reg2 = registryLookup(rawType);
	if (reg2 !== null) return reg2;
	return null as unknown as Type;
}

function rederiveMemberType(node: Node): void {
	const d = node.data as MemberExprData;
	if (d.object === null) return;
	if (d.object.nodeType === null) return;

	const ot = d.object.nodeType;
	const prop = d.property;

	if ((ot.kind === TypeKind.Array || ot.kind === TypeKind.String) && prop === "length") {
		node.nodeType = numberType();
	} else if (ot.kind === TypeKind.String && (prop === "byteLength" || prop === "unicodeLength")) {
		node.nodeType = numberType();
	} else if ((ot.kind === TypeKind.Map || ot.kind === TypeKind.Set) && prop === "size") {
		node.nodeType = numberType();
	} else if (ot.kind === TypeKind.Result) {
		if (prop === "ok") { node.nodeType = booleanType(); }
		else if (prop === "value" && ot.typeReturn !== null) { node.nodeType = ot.typeReturn; }
		else if (prop === "error" && ot.typeExtra !== null) { node.nodeType = ot.typeExtra; }
	} else if (ot.kind === TypeKind.Struct) {
		// Primary: look up field in typeNames/typeChildren
		let found = false;
		if (ot.typeNames !== null) {
			let pi = 0;
			while (pi < ot.typeNames.length) {
				if (ot.typeNames[pi] === prop) {
					if (pi < ot.typeChildren.length) {
						node.nodeType = ot.typeChildren[pi];
						found = true;
					}
					pi = ot.typeNames.length;  // break
				}
				pi = pi + 1;
			}
		}
		// Fallback: well-known field types by typeName (when typeNames not populated)
		if (!found && ot.typeName !== null && node.nodeType === null) {
			recoverKnownField(node, ot.typeName, prop);
		}
	} else if (ot.kind === TypeKind.SizedArray) {
		if (prop === "length") { node.nodeType = numberType(); }
		else if (prop === "data" && ot.typeReturn !== null) { node.nodeType = ot.typeReturn; }
	} else if (ot.kind === TypeKind.Span) {
		if (prop === "length") { node.nodeType = numberType(); }
		else if (prop === "data" && ot.typeReturn !== null) { node.nodeType = ot.typeReturn; }
	} else if (ot.kind === TypeKind.Enum) {
		// Enum member access (e.g. TokenKind.Plus) → the enum type itself
		node.nodeType = ot;
	} else if (ot.kind === TypeKind.Tuple && ot.typeChildren !== null) {
		// Tuple field access by numeric string index (e.g. t.0, t.1)
		// For named tuples, look up in typeNames
		if (ot.typeNames !== null) {
			let pi = 0;
			while (pi < ot.typeNames.length) {
				if (ot.typeNames[pi] === prop && pi < ot.typeChildren.length) {
					node.nodeType = ot.typeChildren[pi];
					pi = ot.typeNames.length;
				}
				pi = pi + 1;
			}
		}
	} else if (ot.kind === TypeKind.TypeReference && ot.typeName !== null && ot.typeName.startsWith("{")) {
		// Structural TypeReference: parse field type from typeName string
		// Format: "{ name : type , name2 : type2 }"
		const fieldType = extractFieldTypeFromStructural(ot.typeName, prop);
		if (fieldType !== null) {
			node.nodeType = fieldType;
		}
	} else if (ot.kind === TypeKind.Function) {
		// Not a typical member access — skip (closures are handled differently)
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
		node.nodeType = charType();  // string indexing returns char
	} else if (at.kind === TypeKind.Tuple && at.typeChildren !== null) {
		// Tuple index access: t[0] → typeChildren[0]
		if (d.index.kind === NodeKind.NumberLiteral) {
			const idx = (d.index.data as NumberLiteralData).value;
			if (idx >= 0 && idx < at.typeChildren.length) {
				node.nodeType = at.typeChildren[idx];
			}
		}
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
		return;
	}

	// Source 3: callee is MemberExpr — look up method in object type or registry
	if (d.callee.kind === NodeKind.MemberExpr) {
		const md = d.callee.data as MemberExprData;
		// Try registry: the method name may be a standalone exported function
		const regType = registryLookup(md.property);
		if (regType !== null && regType.kind === TypeKind.Function && regType.typeReturn !== null) {
			node.nodeType = regType.typeReturn;
		}
	}

	// Source 4: callee is Identifier — try registry for cross-module functions
	if (d.callee.kind === NodeKind.Identifier) {
		const id = d.callee.data as IdentifierData;
		const regType = registryLookup(id.name);
		if (regType !== null && regType.kind === TypeKind.Function && regType.typeReturn !== null) {
			node.nodeType = regType.typeReturn;
		}
	}
}

// ===== BinaryExpr / UnaryExpr / ConditionalExpr derivation =====

function deriveBinaryExprType(node: Node): void {
	const d = node.data as BinaryExprData;
	const op = d.operator;
	const lt = d.left !== null ? d.left.nodeType : null as unknown as Type;
	const rt = d.right !== null ? d.right.nodeType : null as unknown as Type;

	// Comparison and logical operators → boolean
	if (op === "===" || op === "!==" || op === "==" || op === "!=" ||
		op === "<" || op === ">" || op === "<=" || op === ">=" ||
		op === "&&" || op === "||" || op === "instanceof" || op === "in") {
		node.nodeType = booleanType();
		return;
	}

	// String concatenation: + with either operand being string → string
	if (op === "+") {
		if ((lt !== null && lt.kind === TypeKind.String) || (rt !== null && rt.kind === TypeKind.String)) {
			node.nodeType = stringType();
			return;
		}
	}

	// Arithmetic operators → number (if both operands are numeric)
	if (op === "+" || op === "-" || op === "*" || op === "/" || op === "%" ||
		op === "**" || op === "|" || op === "&" || op === "^" ||
		op === "<<" || op === ">>" || op === ">>>") {
		// Prefer left operand's type for sized integers, default to number
		if (lt !== null && isNumeric(lt)) {
			node.nodeType = lt;
		} else if (rt !== null && isNumeric(rt)) {
			node.nodeType = rt;
		} else {
			node.nodeType = numberType();
		}
		return;
	}
}

function deriveUnaryExprType(node: Node): void {
	const d = node.data as UnaryExprData;
	const op = d.unaryOp;
	if (op === "!" || op === "not") {
		node.nodeType = booleanType();
	} else if (op === "-" || op === "+" || op === "~") {
		// Preserve operand's numeric type if available
		if (d.operand !== null && d.operand.nodeType !== null) {
			const ot = d.operand.nodeType;
			if (isNumeric(ot)) {
				node.nodeType = ot;
				return;
			}
		}
		node.nodeType = numberType();
	} else if (op === "typeof") {
		node.nodeType = stringType();
	}
}

function deriveConditionalExprType(node: Node): void {
	const d = node.data as ConditionalExprData;
	// Prefer consequent type, fall back to alternate
	if (d.ternaryConsequent !== null && d.ternaryConsequent.nodeType !== null) {
		node.nodeType = d.ternaryConsequent.nodeType;
	} else if (d.ternaryAlternate !== null && d.ternaryAlternate.nodeType !== null) {
		node.nodeType = d.ternaryAlternate.nodeType;
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

export function refineTypes(program: Node, ctx: TransformContext, registry: ExportRegistry): Node {
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

// Registry Bridge: look up type by name (for TypeAssertion "x as Foo" and enum member access)
// Searches registry symbols for types (interfaces, classes, enums, type aliases)
function registryTypeLookup(name: string): Type {
	if (_registryEntries === null) return null as unknown as Type;
	let ei = 0;
	while (ei < _registryEntries.length) {
		const entry = _registryEntries[ei];
		let si = 0;
		while (si < entry.symbols.length) {
			const sym = entry.symbols[si];
			if (sym.name === name && sym.symType !== null) {
				const k = sym.symType.kind;
				if (k === TypeKind.Struct || k === TypeKind.Enum || k === TypeKind.Array ||
					k === TypeKind.Result || k === TypeKind.Span || k === TypeKind.Tuple ||
					k === TypeKind.Function || k === TypeKind.Ref || k === TypeKind.Ptr) {
					return sym.symType;
				}
			}
			si = si + 1;
		}
		ei = ei + 1;
	}
	return null as unknown as Type;
}

// Desperation heuristic: map common compiler variable names to known types.
// Last resort when resolvedSym, scope, and registry all fail.
function desperationHeuristic(name: string): Type {
	// Suffix-based: *Type/*type → Type, *Sym → Symbol
	if (name.endsWith("Type") || name.endsWith("type")) return registryTypeLookup("Type");
	if (name.endsWith("Sym")) return registryTypeLookup("Symbol");

	// Exact match: common AST variable names → Node
	if (name === "node" || name === "stmt" || name === "elem" || name === "arg" ||
		name === "dec" || name === "member" || name === "left" || name === "right" ||
		name === "body" || name === "expr" || name === "tryExpr" || name === "child" ||
		name === "stmts") {
		return registryTypeLookup("Node");
	}
	if (name === "sym" || name === "symbol") return registryTypeLookup("Symbol");
	if (name === "tok" || name === "token") return registryTypeLookup("Token");
	if (name === "ot" || name === "st") return registryTypeLookup("Type");

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

	// ForOfStmt: seed loop binding with element type from iterable
	if (node.kind === NodeKind.ForOfStmt) {
		const fod = node.data as ForOfStmtData;
		// Recurse iterable first to type it
		refineNode(fod.forOfIterable, scopes);
		// Seed binding with element type
		scopes.push(createScope());
		if (fod.forOfIterable !== null && fod.forOfIterable.nodeType !== null) {
			const iterType = fod.forOfIterable.nodeType;
			if ((iterType.kind === TypeKind.Array || iterType.kind === TypeKind.SizedArray ||
				iterType.kind === TypeKind.Span) && iterType.typeReturn !== null) {
				scopeRecord(scopes, fod.forOfBinding, iterType.typeReturn);
			} else if (iterType.kind === TypeKind.String) {
				scopeRecord(scopes, fod.forOfBinding, charType());
			}
		}
		refineNode(fod.forOfBody, scopes);
		scopes.pop();
		return;
	}

	// ArrowFunction: push scope, seed params if nodeType available, recurse body
	if (node.kind === NodeKind.ArrowFunction) {
		const ad = node.data as ArrowFunctionData;
		scopes.push(createScope());
		// Seed params from arrow's nodeType if available
		if (node.nodeType !== null && node.nodeType.kind === TypeKind.Function) {
			const paramTypes = node.nodeType.typeChildren;
			if (paramTypes !== null && ad.arrowParams !== null) {
				let ai = 0;
				while (ai < ad.arrowParams.length && ai < paramTypes.length) {
					if (paramTypes[ai] !== null) {
						scopeRecord(scopes, ad.arrowParams[ai], paramTypes[ai]);
					}
					ai = ai + 1;
				}
			}
		}
		refineNode(ad.arrowBody, scopes);
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
					} else {
						// Desperation heuristic: common compiler variable names → known types
						const recovered = desperationHeuristic(id.name);
						if (recovered !== null) {
							node.nodeType = recovered;
						}
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
	} else if (node.kind === NodeKind.BinaryExpr) {
		if (node.nodeType === null) {
			deriveBinaryExprType(node);
		}
	} else if (node.kind === NodeKind.UnaryExpr) {
		if (node.nodeType === null) {
			deriveUnaryExprType(node);
		}
	} else if (node.kind === NodeKind.ConditionalExpr) {
		if (node.nodeType === null) {
			deriveConditionalExprType(node);
		}
	} else if (node.kind === NodeKind.TypeAssertion) {
		if (node.nodeType === null) {
			const ta = node.data as TypeAssertionData;
			// Look up the target type name in scope stack then registry
			if (ta.asType.length > 0) {
				const found = scopeLookup(scopes, ta.asType);
				if (found !== null) {
					node.nodeType = found;
				} else {
					const regType = registryTypeLookup(ta.asType);
					if (regType !== null) {
						node.nodeType = regType;
					} else {
						// Also try registryLookup (catches type aliases like BinaryExprData)
						const regType2 = registryLookup(ta.asType);
						if (regType2 !== null) {
							node.nodeType = regType2;
						}
					}
				}
			}
		}
	} else if (node.kind === NodeKind.ReturnStmt) {
		// Propagate argument type to the return node
		const rd = node.data as ReturnStmtData;
		if (node.nodeType === null && rd.argument !== null && rd.argument.nodeType !== null) {
			node.nodeType = rd.argument.nodeType;
		}
	}
}

// Seed scope with function parameter types from FunctionDecl.nodeType
function seedFunctionParams(fnNode: Node, scopes: TypeScope[]): void {
	if (fnNode.nodeType === null) return;
	const fnType = fnNode.nodeType;
	if (fnType.kind !== TypeKind.Function) return;

	const d = fnNode.data as FunctionDeclData;
	const paramNames = d.params;
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
