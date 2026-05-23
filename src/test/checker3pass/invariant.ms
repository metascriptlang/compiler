// 3-pass Checker Post-Pass-3 Invariant Walker
//
// Core invariant under enforcement:
//
//   "After Pass 3, no `node.nodeType` may contain TypeKind.GenericParam
//    at any depth, EXCEPT inside template (uninstantiated generic) decls
//    where GenericParam is the legitimate parametric placeholder."
//
// Vi phạm signature pattern:
//   - lifted closure inheriting `T` from un-substituted formal at call site
//   - method call missing receiver-type substitution
//   - constructor arg with unsubstituted class generic
//   - ternary/match arm propagating generic expectedType to closure body
//
// Returns: list of violations with enough context to triage.

import { Node, NodeKind, Type, TypeKind, FunctionDeclData, MethodDeclData, ClassDeclData, ArrowFunctionData, FunctionExprData } from "../../ast/node";
import { walkChildrenForCheck } from "./helpers";
import { isGenericFn } from "../../checker/context";

export interface InvariantViolation {
	nodeKind: NodeKind;
	typePath: string;          // e.g. "typeChildren[0]", "typeReturn", "typeChildren[2].typeReturn"
	leakedTypeName: string;
	contextName: string;
	line: int32;
	column: int32;
}

// Walk the post-Pass-3 program. Skip template decls (legitimate parametric).
// For ArrowFunction / FunctionExpr nodes (closure literals — the load-bearing
// shape for the BUG #2 family), verify nodeType has no leaked GenericParam.
//
// Other node kinds (MemberExpr/Identifier referring to a generic-method-as-
// value, etc.) MAY legitimately carry GenericParam in nodeType because they
// represent parametric references — the call site is where instantiation
// happens. Restricting the check to closure literals keeps the invariant
// signal-to-noise high and aligned with the actual silent-corruption family.
export function checkNoGenericParamLeakage(program: Node): InvariantViolation[] {
	const violations: InvariantViolation[] = [];
	walkAndCheck(program, "<program>", false, violations);
	return violations;
}

// Recursive walker. `inTemplate` propagates down so nodes inside a generic
// template decl skip the invariant (legitimate parametric).
function walkAndCheck(node: Node, contextName: string, inTemplate: boolean, out: InvariantViolation[]): void {
	if (node === null) return;

	let nextContext = contextName;
	let nextInTemplate = inTemplate;
	match (node.kind) {
		NodeKind.FunctionDecl => {
			const fd = node.data as FunctionDeclData;
			nextContext = `FunctionDecl '${fd.fnName}'`;
			if (isGenericFn(fd.fnFlags)) nextInTemplate = true;
		},
		NodeKind.MethodDecl => {
			const md = node.data as MethodDeclData;
			nextContext = `MethodDecl '${md.methodName}'`;
			if (isGenericFn(md.methodFlags)) nextInTemplate = true;
		},
		NodeKind.ClassDecl => {
			const cd = node.data as ClassDeclData;
			nextContext = `ClassDecl '${cd.className}'`;
		},
		_ => {},
	};

	const isClosureLiteral = node.kind === NodeKind.ArrowFunction || node.kind === NodeKind.FunctionExpr;
	if (!nextInTemplate && isClosureLiteral && node.nodeType !== null) {
		const leak = findGenericParamInType(node.nodeType, "");
		if (leak.found) {
			out.push({
				nodeKind: node.kind,
				typePath: leak.path,
				leakedTypeName: leak.name,
				contextName: nextContext,
				line: node.location !== null ? node.location.line : 0,
				column: node.location !== null ? node.location.column : 0,
			});
		}
	}

	walkChildrenForCheck(node, (child: Node): boolean => {
		walkAndCheck(child, nextContext, nextInTemplate, out);
		return false; // collect ALL violations, don't short-circuit
	});
}

interface LeakResult {
	found: boolean;
	path: string;
	name: string;
}

// Returns the first GenericParam encountered with its dot-path location
// (typeChildren[0].typeReturn, etc.) for diagnostics. See `Type Storage
// Schema` block in src/checker/types.ms for field semantics.
function findGenericParamInType(t: Type, path: string): LeakResult {
	if (t === null) return { found: false, path: "", name: "" };

	if (t.kind === TypeKind.GenericParam) {
		return { found: true, path: path === "" ? "<self>" : path, name: t.typeName };
	}

	// Nominal struct/union: skip recursion. Inner GenericParam references
	// are bound via typeChildren at the type's instantiation site, not at
	// this reference point.
	if ((t.kind === TypeKind.Struct || t.kind === TypeKind.Union) && t.typeName !== "") {
		return { found: false, path: "", name: "" };
	}

	if (t.typeReturn !== null) {
		const r = findGenericParamInType(t.typeReturn, path === "" ? "typeReturn" : path + ".typeReturn");
		if (r.found) return r;
	}

	if (t.typeExtra !== null) {
		const r = findGenericParamInType(t.typeExtra, path === "" ? "typeExtra" : path + ".typeExtra");
		if (r.found) return r;
	}

	if (t.typeChildren !== null) {
		for (let i = 0; i < t.typeChildren.length; i = i + 1) {
			const child = t.typeChildren[i];
			const childPath = (path === "" ? "typeChildren[" : path + ".typeChildren[") + i.toString() + "]";
			const r = findGenericParamInType(child, childPath);
			if (r.found) return r;
		}
	}

	return { found: false, path: "", name: "" };
}

export function formatViolation(v: InvariantViolation): string {
	return `[INV-VIOLATION] ${v.contextName} @ line ${v.line} — node kind=${v.nodeKind} leaked GenericParam '${v.leakedTypeName}' at ${v.typePath}`;
}

export function formatViolations(vs: InvariantViolation[]): string {
	if (vs.length === 0) return "(no violations)";
	let out = `${vs.length} invariant violation(s):\n`;
	for (const v of vs) { out = `${out}  ${formatViolation(v)}\n`; }
	return out;
}
