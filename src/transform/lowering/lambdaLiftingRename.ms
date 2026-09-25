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
	counter: int32;
	frameNames: string[];
	frameStarts: int32[];
	tag: string;
}

function boundInOpenFrame(st: RenameState, name: string): boolean {
	for (const n of st.frameNames) { if (n == name) return true; }
	return false;
}

function pushFrame(st: RenameState): void {
	pushScope(st);
	st.frameStarts.push(st.frameNames.length);
}

function popFrame(st: RenameState): void {
	const start = st.frameStarts[st.frameStarts.length - 1];
	while (st.frameNames.length > start) st.frameNames.pop();
	st.frameStarts.pop();
	popScope(st);
}

function pushScope(st: RenameState): void {
	st.scopes.push({ origNames: [], newNames: [] });
}

function popScope(st: RenameState): void {
	st.scopes.pop();
}

function defineIn(st: RenameState, orig: string, renamed: string): void {
	if (st.scopes.length == 0) return;
	const sc = st.scopes[st.scopes.length - 1];
	sc.origNames.push(orig);
	sc.newNames.push(renamed);
}

function lookupRenamed(st: RenameState, name: string): string {
	for (let i = st.scopes.length - 1; i >= 0; i -= 1) {
		const sc = st.scopes[i];
		for (let j = sc.origNames.length - 1; j >= 0; j -= 1) {
			if (sc.origNames[j] == name) return sc.newNames[j];
		}
	}
	return "";
}

function declareParam(st: RenameState, name: string): void {
	defineIn(st, name, name);
	if (st.frameStarts.length > 0) st.frameNames.push(name);
}

// Module-scope bindings keep their names: they are C globals, cross-module
// references resolve to them by name, and lifting never puts them in an env.
function declareBinding(st: RenameState, name: string, renameSiblings: boolean = true): string {
	if (name == "" || name == "this" || name.startsWith("$")) {
		defineIn(st, name, name);
		return name;
	}
	if (st.frameStarts.length == 0) {
		defineIn(st, name, name);
		return name;
	}
	let bound = name;
	if (lookupRenamed(st, name) != "" || (renameSiblings && boundInOpenFrame(st, name))) {
		st.counter += 1;
		bound = name + st.tag + st.counter.toString();
	}
	defineIn(st, name, bound);
	st.frameNames.push(name);
	return bound;
}

function walkFrame(st: RenameState, params: string[], body: Node, defaults: Node[]): void {
	pushFrame(st);
	for (const p of params) declareParam(st, p);
	for (const dv of defaults) walkRename(dv, st);
	walkRename(body, st);
	popFrame(st);
}

function walkRename(node: Node | null, st: RenameState): void {
	if (node == null) return;
	if (node.kind == NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		const mapped = lookupRenamed(st, d.name);
		if (mapped != "" && mapped != d.name) d.name = mapped;
		return;
	}
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		const isSelfRefClosureInit = d.initializer != null
			&& (d.initializer.kind == NodeKind.ArrowFunction
				|| d.initializer.kind == NodeKind.FunctionExpr);
		if (isSelfRefClosureInit) {
			d.declName = declareBinding(st, d.declName);
			walkRename(d.initializer, st);
		} else {
			walkRename(d.initializer, st);
			d.declName = declareBinding(st, d.declName);
		}
		return;
	}
	if (node.kind == NodeKind.BlockStmt) {
		pushScope(st);
		for (const s of (node.data as BlockStmtData).statements) walkRename(s, st);
		popScope(st);
		return;
	}
	if (node.kind == NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		walkFrame(st, d.params, d.fnBody, d.fnDefaults);
		return;
	}
	if (node.kind == NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		walkFrame(st, d.methodParams, d.methodBody, d.methodDefaults);
		return;
	}
	if (node.kind == NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		walkFrame(st, d.ctorParams, d.ctorBody, d.ctorDefaults);
		return;
	}
	if (node.kind == NodeKind.TestDecl) {
		const d = node.data as TestDeclData;
		walkFrame(st, [], d.testBody, []);
		return;
	}
	if (node.kind == NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		pushFrame(st);
		for (const p of d.arrowParams) declareParam(st, p);
		for (const dv of d.arrowDefaults) { if (dv != null) walkRename(dv, st); }
		walkRename(d.arrowBody, st);
		popFrame(st);
		return;
	}
	if (node.kind == NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		walkFrame(st, d.funcExprParams, d.funcExprBody, []);
		return;
	}
	if (node.kind == NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		pushScope(st);
		walkRename(d.forInit, st);
		walkRename(d.forCondition, st);
		walkRename(d.forUpdate, st);
		walkRename(d.forBody, st);
		popScope(st);
		return;
	}
	if (node.kind == NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		walkRename(d.forOfIterable, st);
		pushScope(st);
		if (d.forOfBinding != "") d.forOfBinding = declareBinding(st, d.forOfBinding);
		walkRename(d.forOfPattern, st);
		walkRename(d.forOfBody, st);
		popScope(st);
		return;
	}
	if (node.kind == NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		walkRename(d.tryBody, st);
		pushScope(st);
		if (d.catchName != "") d.catchName = declareBinding(st, d.catchName, false);
		walkRename(d.catchBody, st);
		popScope(st);
		walkRename(d.finallyBody, st);
		return;
	}
	mapChildren(node, (child: Node): Node => { walkRename(child, st); return child; });
}

export function renameRepeatedBindings(program: Node): Node {
	const st: RenameState = { scopes: [], counter: 0, frameNames: [], frameStarts: [], tag: "$s" };
	pushScope(st);
	walkRename(program, st);
	popScope(st);
	return program;
}

export function renameRepeatedBindingsInFrame(params: string[], body: Node, tag: string): void {
	const st: RenameState = { scopes: [], counter: 0, frameNames: [], frameStarts: [], tag };
	pushScope(st);
	walkFrame(st, params, body, []);
	popScope(st);
}
