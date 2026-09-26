// Object Literal Completion (JS backend) — fill omitted struct fields with
// their zero value so JS object shapes match C's zero-filled struct literals.
// Without this, an omitted nullable field is `undefined` in JS and
// `field === null` diverges from the C backend (strict equality misses it).
//
// { tag: "x" } checked as Box { w: number | null, tag: string }
//   → { tag: "x", w: null }
//
// Skips: extern types (real JS APIs distinguish absent vs null), literals
// where keys/properties are out of sync (spread — lowered elsewhere).

import { Node, NodeKind, ObjectLiteralData, SpreadExprData, TypeKind } from "../../ast/node";
import { peelThrough, PEEL_ALL, unwrapRef } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeDefaultValue } from "../util";
import { spreadStructOf } from "../desugar/objectSpreadLower";

export function lowerObjectLiteralComplete(program: Node, ctx: TransformContext): Node {
	walkNode(program, completeLiteral);
	return program;
}

function completeLiteral(node: Node): Node {
	if (node.kind != NodeKind.ObjectLiteral) return node;
	if (node.nodeType == null) return node;
	const peeled = peelThrough(unwrapRef(node.nodeType), PEEL_ALL);
	const t = peeled == null ? unwrapRef(node.nodeType) : peeled;
	if (t.kind != TypeKind.Struct) return node;
	if (t.typeNames == null || t.typeChildren == null) return node;
	if (t.sym != null && hasFlag(t.sym, SymbolFlag.ImportC)) return node;
	const d = node.data as ObjectLiteralData;
	if (d.keys.length != d.properties.length) return node;
	for (let i = 0; i < t.typeNames.length; i += 1) {
		const fieldName = t.typeNames[i];
		if (fieldName.startsWith("__")) continue;
		if (hasKey(d.keys, fieldName) || spreadMayProvide(d, fieldName)) continue;
		const fieldType = t.typeChildren[i];
		if (fieldType.kind == TypeKind.Function) continue;
		d.keys.push(fieldName);
		d.properties.push(makeDefaultValue(fieldType, node.location));
	}
	return node;
}

function spreadMayProvide(d: ObjectLiteralData, name: string): boolean {
	for (let i = 0; i < d.keys.length; i += 1) {
		if (d.keys[i] != "..." || d.properties[i].kind != NodeKind.SpreadExpr) continue;
		const src = spreadStructOf((d.properties[i].data as SpreadExprData).spreadArg.nodeType);
		if (src == null || src.typeNames.includes(name)) return true;
	}
	return false;
}

function hasKey(keys: string[], name: string): boolean {
	for (const k of keys) {
		if (k == name) return true;
	}
	return false;
}
