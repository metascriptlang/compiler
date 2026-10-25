import { Node, NodeKind, SymbolKind, Symbol, VariableDeclData, IdentifierData } from "../../ast/node";
import { TransformContext, SymSet, createSymSet, symSetAdd, symSetContains, reportTransformError } from "../context";
import { mapChildren, isFuncBoundary } from "../walker";
import { anyDescendant, Visit } from "../../ast/visitor";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import {
	ScopeStack, defineVar, isLocalVar, isOuterVar, isModuleLevelVar, isOuterFrameName,
} from "./lambdaLiftingScope";

// ===== Phase F: Last-Use Capture Detection =====
// Check if a binding is read in any statement after index `afterIdx`.
// Used to determine if a capture can be moved instead of copied.

function nodeRefsSym(node: Node, sym: Symbol): boolean {
	return anyDescendant(node, (n: Node): Visit => {
		if (n.kind == NodeKind.Identifier) return n.resolvedSym == sym ? Visit.Hit : Visit.Skip;
		return isFuncBoundary(n) ? Visit.Skip : Visit.Descend;
	});
}

export function isCaptureLastUse(sym: Symbol, closureIdx: number, stmts: Node[]): boolean {
	let i = closureIdx + 1;
	while (i < stmts.length) {
		if (nodeRefsSym(stmts[i], sym)) return false;
		i += 1;
	}
	return true;
}

export function computeLastUseCaptures(captures: SymSet, closureIdx: number, stmts: Node[]): SymSet {
	const result = createSymSet();
	for (const sym of captures.items) {
		if (isCaptureLastUse(sym, closureIdx, stmts)) {
			symSetAdd(result, sym);
		}
	}
	return result;
}

// Detection logic lives in `lambdaLiftingDetect.ms` (Pass 1).

// ===== Capture Detection =====
// Detect which outer bindings a function body references.
// Walk the body recursively, collecting the symbols bound in outer scopes.

interface CaptureWalk {
	captured: SymSet;
	idents: Node[];
	ss: ScopeStack;
	routine: Symbol | null;
	report: TransformContext | null;
}

export function detectCaptures(body: Node, ss: ScopeStack, identNodes: Node[], routine: Symbol | null, report: TransformContext | null): SymSet {
	const walk: CaptureWalk = { captured: createSymSet(), idents: identNodes, ss, routine, report };
	collectCaptures(body, walk);
	return walk.captured;
}

function collectCaptures(node: Node, walk: CaptureWalk): void {
	if (node == null) return;
	if (node.kind == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym == null) {
			const name = (node.data as IdentifierData).name;
			if (walk.report != null && isOuterFrameName(walk.ss, name)) {
				reportTransformError(walk.report, `internal: the reference to '${name}' reached lambda lifting without its symbol`, node.location);
			}
			return;
		}
		if (walk.routine != null && sym == walk.routine) return;
		if (!isLocalVar(walk.ss, sym) && isOuterVar(walk.ss, sym)) {
			// Reference parity (interestingVar): skip types — not runtime values.
			const sk = sym.symbolKind;
			if (sk == SymbolKind.Class || sk == SymbolKind.Interface
				|| sk == SymbolKind.TypeAlias || sk == SymbolKind.Enum) {
				return;
			}
			const isModLevel = (sk == SymbolKind.Variable || sk == SymbolKind.Temp || sk == SymbolKind.Parameter)
				? hasFlag(sym, SymbolFlag.Global)
				: isModuleLevelVar(walk.ss, sym);
			if (!isModLevel) {
				if (!symSetContains(walk.captured, sym)) {
					walk.idents.push(node);
				}
				symSetAdd(walk.captured, sym);
			}
		}
		return;
	}
	if (isFuncBoundary(node)) return;
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		collectCaptures(d.initializer, walk);
		defineVar(walk.ss, node.resolvedSym, d.declName);
		return;
	}
	mapChildren(node, (child: Node): Node => { collectCaptures(child, walk); return child; });
}

export function findCapturedIdent(sym: Symbol, capturedIdents: Node[]): Node {
	for (const n of capturedIdents) {
		if (n.resolvedSym == sym) return n;
	}
	return null as unknown as Node;
}
