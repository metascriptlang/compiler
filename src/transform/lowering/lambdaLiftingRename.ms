// Shadowed-binding uniquification (Pass 0 of lambda lifting).
//
// Reference keys captures and env fields by symbol id, never by name:
// `capturedVars.incl(s.id)` (lambdalifting.nim:516) and `addField` →
// `lookupInRecord(obj.n, s.itemId)` (lowerings.nim:241), whose own comment
// records that two distinct same-named captures legitimately get distinct
// fields. Our lift machinery is string-keyed throughout — capture sets, env
// field names, active rewrites, loop redirects — so a binding that shadows a
// captured name aliases the outer binding's env slot instead of getting its
// own. Renaming the inner binding restores "one name is one binding" for the
// whole lifting universe without introducing a second identity channel.

import {
	Node, NodeKind, IdentifierData, VariableDeclData, BlockStmtData,
	ArrowFunctionData, FunctionExprData, FunctionDeclData, MethodDeclData,
	ConstructorDeclData, TestDeclData, ForStmtData, ForOfStmtData,
	TryCatchStmtData,
} from "../../ast/node";
import { mapChildren } from "../walker";

interface RenameScope {
	origNames: string[];
	newNames: string[];
}

interface RenameState {
	scopes: RenameScope[];
	frameDepth: int32;
	counter: int32;
}

function pushScope(st: RenameState): void {
	st.scopes.push({ origNames: [], newNames: [] });
}

function popScope(st: RenameState): void {
	st.scopes.pop();
}

function defineIn(st: RenameState, orig: string, renamed: string): void {
	if (st.scopes.length === 0) return;
	const sc = st.scopes[st.scopes.length - 1];
	sc.origNames.push(orig);
	sc.newNames.push(renamed);
}

function lookupRenamed(st: RenameState, name: string): string {
	for (let i = st.scopes.length - 1; i >= 0; i -= 1) {
		const sc = st.scopes[i];
		for (let j = sc.origNames.length - 1; j >= 0; j -= 1) {
			if (sc.origNames[j] === name) return sc.newNames[j];
		}
	}
	return "";
}

function declareParam(st: RenameState, name: string): void {
	defineIn(st, name, name);
}

// Module-scope bindings keep their names: they are C globals, cross-module
// references resolve to them by name, and lifting never puts them in an env.
function declareBinding(st: RenameState, name: string): string {
	if (name === "" || name === "this" || name.startsWith("$")) {
		defineIn(st, name, name);
		return name;
	}
	if (st.frameDepth === 0 || lookupRenamed(st, name) === "") {
		defineIn(st, name, name);
		return name;
	}
	st.counter += 1;
	const fresh = name + "$s" + st.counter.toString();
	defineIn(st, name, fresh);
	return fresh;
}

function walkFrame(st: RenameState, params: string[], body: Node, defaults: Node[]): void {
	pushScope(st);
	st.frameDepth += 1;
	for (const p of params) declareParam(st, p);
	for (const dv of defaults) walkRename(dv, st);
	walkRename(body, st);
	st.frameDepth -= 1;
	popScope(st);
}

function walkRename(node: Node | null, st: RenameState): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		const mapped = lookupRenamed(st, d.name);
		if (mapped !== "" && mapped !== d.name) d.name = mapped;
		return;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		const isSelfRefClosureInit = d.initializer !== null
			&& (d.initializer.kind === NodeKind.ArrowFunction
				|| d.initializer.kind === NodeKind.FunctionExpr);
		if (isSelfRefClosureInit) {
			d.declName = declareBinding(st, d.declName);
			walkRename(d.initializer, st);
		} else {
			walkRename(d.initializer, st);
			d.declName = declareBinding(st, d.declName);
		}
		return;
	}
	if (node.kind === NodeKind.BlockStmt) {
		pushScope(st);
		for (const s of (node.data as BlockStmtData).statements) walkRename(s, st);
		popScope(st);
		return;
	}
	if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		walkFrame(st, d.params, d.fnBody, d.fnDefaults);
		return;
	}
	if (node.kind === NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		walkFrame(st, d.methodParams, d.methodBody, d.methodDefaults);
		return;
	}
	if (node.kind === NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		walkFrame(st, d.ctorParams, d.ctorBody, d.ctorDefaults);
		return;
	}
	if (node.kind === NodeKind.TestDecl) {
		const d = node.data as TestDeclData;
		walkFrame(st, [], d.testBody, []);
		return;
	}
	if (node.kind === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		pushScope(st);
		st.frameDepth += 1;
		for (const p of d.arrowParams) declareParam(st, p);
		for (const dv of d.arrowDefaults) { if (dv !== null) walkRename(dv, st); }
		walkRename(d.arrowBody, st);
		st.frameDepth -= 1;
		popScope(st);
		return;
	}
	if (node.kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		walkFrame(st, d.funcExprParams, d.funcExprBody, []);
		return;
	}
	if (node.kind === NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		pushScope(st);
		walkRename(d.forInit, st);
		walkRename(d.forCondition, st);
		walkRename(d.forUpdate, st);
		walkRename(d.forBody, st);
		popScope(st);
		return;
	}
	if (node.kind === NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		walkRename(d.forOfIterable, st);
		pushScope(st);
		if (d.forOfBinding !== "") d.forOfBinding = declareBinding(st, d.forOfBinding);
		walkRename(d.forOfPattern, st);
		walkRename(d.forOfBody, st);
		popScope(st);
		return;
	}
	if (node.kind === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		walkRename(d.tryBody, st);
		pushScope(st);
		if (d.catchName !== "") d.catchName = declareBinding(st, d.catchName);
		walkRename(d.catchBody, st);
		popScope(st);
		walkRename(d.finallyBody, st);
		return;
	}
	mapChildren(node, (child: Node): Node => { walkRename(child, st); return child; });
}

export function renameShadowedBindings(program: Node): Node {
	const st: RenameState = { scopes: [], frameDepth: 0, counter: 0 };
	pushScope(st);
	walkRename(program, st);
	popScope(st);
	return program;
}
