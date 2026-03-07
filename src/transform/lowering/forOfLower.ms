// For-Of Lowering — transforms for-of loops into index-based while loops
// Follows reference for_of_lower.zig
//
// Arrays/Strings:
//   for (const item of arr) { body }
//   → { const $iter = arr; let $idx = 0; const $len = $iter.length;
//       while ($idx < $len) { const item = $iter[$idx]; body; $idx++; } }
//
// Maps/Sets (slot-scan pattern):
//   for (const key of map) { body }
//   → { const $iter = map; let $slot = 0; const $cap = msMapCap($iter);
//       while ($slot < $cap) {
//         if (msMapSlotState($iter, $slot) == 2) {
//           const key = msMapSlotKey($iter, $slot); body; }
//         $slot++; } }

import {
	Node, NodeKind, DeclKind, ForOfStmtData, SourceLocation,
	ArrayPatternData, IdentifierData, NF_CURSOR,
} from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { Type, TypeKind, numberType, stringType } from "../../checker/types";
import { walkNode } from "../walker";
import {
	makeIdent, makeTypedIdent, makeNumber, makeBlock, makeVarDecl, makeWhile,
	makeBinary, makeAssign, makeExprStmt, makeMember, makeArrayAccess, makeCall, makeIf,
	extractBodyStmts, boolToDeclKind,
} from "../util";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerForOf(program: Node, ctx: TransformContext): Node {
	return walkNode(program, forOfVisitor(ctx));
}

// Closure-returning visitor to capture ctx
function forOfVisitor(ctx: TransformContext): (node: Node) => Node {
	return (node: Node): Node => {
		if (node.kind !== NodeKind.ForOfStmt) return node;
		const d = node.data as ForOfStmtData;
		const loc = node.location;
		const iterType = d.forOfIterable.nodeType;

		// Map/Set: slot-scan pattern
		if (iterType !== null && (iterType.kind === TypeKind.Map || iterType.kind === TypeKind.Set)) {
			return lowerCollectionForOf(d, iterType, ctx, loc);
		}

		// Array/String: index-based pattern
		return lowerArrayForOf(d, ctx, loc);
	};
}

// ===== Array/String For-Of =====

function lowerArrayForOf(d: ForOfStmtData, ctx: TransformContext, loc: SourceLocation): Node {
	const iterName = freshTemp(ctx, "iter");
	const idxName = freshTemp(ctx, "idx");
	const lenName = freshTemp(ctx, "len");
	const iterType = d.forOfIterable.nodeType;

	// const $iter = arr; — cursor (borrow), DRC must not destroy (Nim: sfCursor)
	const iterDecl = makeVarDecl(iterName, d.forOfIterable, DeclKind.Const, loc);
	iterDecl.flags = iterDecl.flags | NF_CURSOR;

	// let $idx = 0;
	const idxDecl = makeVarDecl(idxName, makeNumber(0, loc), DeclKind.Let, loc);

	// const $len = $iter.length;
	const lenExpr = makeMember(makeTypedIdent(iterName, iterType, loc), "length", loc);
	const lenDecl = makeVarDecl(lenName, lenExpr, DeclKind.Const, loc);

	// $idx = $idx + 1;
	const increment = makeAssign(
		makeTypedIdent(idxName, numberType(), loc),
		makeBinary(makeTypedIdent(idxName, numberType(), loc), "+", makeNumber(1, loc), loc),
		loc
	);
	const incStmt = makeExprStmt(increment, loc);

	// Build while body — bindings scoped inside the loop iteration
	const whileStmts: Node[] = [];
	const itemDk = boolToDeclKind(d.forOfIsConst);

	if (d.forOfPattern !== null && d.forOfPattern.kind === NodeKind.ArrayPattern) {
		// Destructured: const $elem = $iter[$idx]; const a = $elem[0]; const b = $elem[1]; ...
		const elemName = freshTemp(ctx, "elem");
		const elemAccess = makeArrayAccess(makeTypedIdent(iterName, iterType, loc), makeTypedIdent(idxName, numberType(), loc), loc);
		const elemDecl = makeVarDecl(elemName, elemAccess, DeclKind.Const, loc);
		// Propagate element type for nativeLower (tuple → member access)
		if (iterType !== null && iterType.typeReturn !== null) {
			elemDecl.nodeType = iterType.typeReturn;
		}
		whileStmts.push(elemDecl);
		const bindings = expandArrayPattern(d.forOfPattern, makeIdent(elemName, loc), itemDk, loc);
		let pi = 0;
		while (pi < bindings.length) {
			whileStmts.push(bindings[pi]);
			pi += 1;
		}
	} else {
		// Simple binding: const item = $iter[$idx];
		// NF_CURSOR: for-of binding is a borrow from the array — DRC must skip destroy (Nim: sfCursor)
		const itemAccess = makeArrayAccess(makeTypedIdent(iterName, iterType, loc), makeTypedIdent(idxName, numberType(), loc), loc);
		const itemDecl = makeVarDecl(d.forOfBinding, itemAccess, itemDk, loc);
		itemDecl.flags = itemDecl.flags | NF_CURSOR;
		whileStmts.push(itemDecl);
	}

	const bodyStmts = extractBodyStmts(d.forOfBody);
	let bi = 0;
	while (bi < bodyStmts.length) {
		whileStmts.push(bodyStmts[bi]);
		bi += 1;
	}
	whileStmts.push(incStmt);

	const whileCond = makeBinary(makeTypedIdent(idxName, numberType(), loc), "<", makeTypedIdent(lenName, numberType(), loc), loc);
	const whileBody = makeBlock(whileStmts, loc);
	const whileNode = makeWhile(whileCond, whileBody, loc);

	return makeBlock([iterDecl, idxDecl, lenDecl, whileNode], loc);
}

// ===== Map/Set For-Of (slot-scan) =====

function lowerCollectionForOf(d: ForOfStmtData, iterType: Type, ctx: TransformContext, loc: SourceLocation): Node {
	const iterName = freshTemp(ctx, "iter");
	const slotName = freshTemp(ctx, "slot");
	const capName = freshTemp(ctx, "cap");

	// const $iter = iterable; — cursor (borrow), DRC must not destroy (Nim: sfCursor)
	const iterDecl = makeVarDecl(iterName, d.forOfIterable, DeclKind.Const, loc);
	iterDecl.flags = iterDecl.flags | NF_CURSOR;

	// let $slot = 0;
	const slotDecl = makeVarDecl(slotName, makeNumber(0, loc), DeclKind.Let, loc);

	// const $cap = msMapCap($iter);
	const capExpr = makeCall(makeIdent("msMapCap", loc), [makeTypedIdent(iterName, iterType, loc)], loc);
	const capDecl = makeVarDecl(capName, capExpr, DeclKind.Const, loc);

	// Bindings inside the if-guarded block (shadowing safety: scoped per iteration)
	const itemDk = boolToDeclKind(d.forOfIsConst);
	const innerStmts: Node[] = [];

	if (d.forOfPattern !== null && d.forOfPattern.kind === NodeKind.ArrayPattern && iterType.kind === TypeKind.Map) {
		// Map destructured: for (const [k, v] of map) → bind key + value from slot
		const apd = d.forOfPattern.data as ArrayPatternData;
		const isNumericKey = iterType.typeReturn !== null && iterType.typeReturn.kind === TypeKind.Number;
		// Element 0 → msMapSlotKey (key), with msKeyToNum unwrap for numeric maps
		if (apd.patternElements.length > 0 && apd.patternElements[0].kind === NodeKind.Identifier) {
			const keyId = apd.patternElements[0].data as IdentifierData;
			if (keyId.name !== "_") {
				let keyExpr: Node = makeCall(makeIdent("msMapSlotKey", loc), [
					makeTypedIdent(iterName, iterType, loc),
					makeTypedIdent(slotName, numberType(), loc),
				], loc);
				if (isNumericKey) {
					keyExpr = makeCall(makeIdent("msKeyToNum", loc), [keyExpr], loc);
					keyExpr.nodeType = numberType();
				} else {
					keyExpr.nodeType = stringType();
				}
				innerStmts.push(makeVarDecl(keyId.name, keyExpr, itemDk, loc));
			}
		}
		// Element 1 → msMapSlotValue (value)
		if (apd.patternElements.length > 1 && apd.patternElements[1].kind === NodeKind.Identifier) {
			const valId = apd.patternElements[1].data as IdentifierData;
			if (valId.name !== "_") {
				const valExpr = makeCall(makeIdent("msMapSlotValue", loc), [
					makeTypedIdent(iterName, iterType, loc),
					makeTypedIdent(slotName, numberType(), loc),
				], loc);
				// Critical: set nodeType for C-level casting (void* → value type)
				if (iterType.typeExtra !== null) {
					valExpr.nodeType = iterType.typeExtra;
				}
				innerStmts.push(makeVarDecl(valId.name, valExpr, itemDk, loc));
			}
		}
	} else {
		// Non-destructured: yields keys
		let keyExpr: Node = makeCall(makeIdent("msMapSlotKey", loc), [
			makeTypedIdent(iterName, iterType, loc),
			makeTypedIdent(slotName, numberType(), loc),
		], loc);
		// Unwrap numeric keys
		if (iterType.typeReturn !== null && iterType.typeReturn.kind === TypeKind.Number) {
			keyExpr = makeCall(makeIdent("msKeyToNum", loc), [keyExpr], loc);
			keyExpr.nodeType = numberType();
		}
		innerStmts.push(makeVarDecl(d.forOfBinding, keyExpr, itemDk, loc));
	}

	// Original body stmts
	const bodyStmts = extractBodyStmts(d.forOfBody);
	let bi = 0;
	while (bi < bodyStmts.length) {
		innerStmts.push(bodyStmts[bi]);
		bi += 1;
	}
	const innerBlock = makeBlock(innerStmts, loc);

	// if (msMapSlotState($iter, $slot) == 2) { innerBlock }
	const stateExpr = makeCall(makeIdent("msMapSlotState", loc), [
		makeTypedIdent(iterName, iterType, loc),
		makeTypedIdent(slotName, numberType(), loc),
	], loc);
	const ifCond = makeBinary(stateExpr, "===", makeNumber(2, loc), loc);
	const ifNode = makeIf(ifCond, innerBlock, null as unknown as Node, loc);

	// $slot = $slot + 1;
	const increment = makeAssign(
		makeTypedIdent(slotName, numberType(), loc),
		makeBinary(makeTypedIdent(slotName, numberType(), loc), "+", makeNumber(1, loc), loc),
		loc
	);
	const incStmt = makeExprStmt(increment, loc);

	// while ($slot < $cap) { if (...) { ... }; $slot++; }
	const whileStmts: Node[] = [];
	whileStmts.push(ifNode);
	whileStmts.push(incStmt);
	const whileCond = makeBinary(makeTypedIdent(slotName, numberType(), loc), "<", makeTypedIdent(capName, numberType(), loc), loc);
	const whileBody = makeBlock(whileStmts, loc);
	const whileNode = makeWhile(whileCond, whileBody, loc);

	return makeBlock([iterDecl, slotDecl, capDecl, whileNode], loc);
}

// ===== Pattern Expansion Helper =====

function expandArrayPattern(pattern: Node, baseExpr: Node, dk: DeclKind, loc: SourceLocation): Node[] {
	const apd = pattern.data as ArrayPatternData;
	const items: Node[] = [];
	let i = 0;
	while (i < apd.patternElements.length) {
		const elem = apd.patternElements[i];
		if (elem.kind === NodeKind.Identifier) {
			const id = elem.data as IdentifierData;
			if (id.name !== "_") {
				const access = makeArrayAccess(baseExpr, makeNumber(i, loc), loc);
				items.push(makeVarDecl(id.name, access, dk, loc));
			}
		}
		i += 1;
	}
	return items;
}

// ===== Tests =====
test "for-of becomes block" { assert firstStmtKindAfter("for (const x of arr) { use(x); }", lowerForOf) === NodeKind.BlockStmt; }

test "regular for unchanged" { assert firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForOf) === NodeKind.ForStmt; }

test "for-of preserves surrounding stmts" { assert stmtCountAfter("x(); for (const i of arr) {} y();", lowerForOf) === 3; }

test "destructured for-of becomes block" { assert firstStmtKindAfter("for (const [a, b] of arr) { use(a); }", lowerForOf) === NodeKind.BlockStmt; }

test "destructured for-of preserves surrounding" { assert stmtCountAfter("x(); for (const [a, b] of arr) {} y();", lowerForOf) === 3; }
