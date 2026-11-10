import { ImportEntry } from "../../module/graph";
import {
	Node,
	NodeKind,
	Symbol,
	SymbolKind,
	Type,
	TypeKind,
	BuiltinKind,
	MemberExprData,
	CallExprData,
	BinaryExprData,
	UpdateExprData,
	ArrayAccessData,
	HiddenDerefData,
	HiddenStdConvData,
	ProgramData,
} from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { isAssignOp } from "../../ast/operators";
import { PEEL_ALIAS, getBuiltinKind, peelThrough, typeDisplayName } from "../../checker/types";
import { jsMethodMemberName } from "../../codegen/js/expressions";
import {
	BoundaryRefusal,
	MemberAccess,
	MemberUse,
	handleTarget,
	isHandleType,
} from "./manifest";

function unlocated(
	file: string,
	code: string,
	message: string,
): BoundaryRefusal {
	return { file, code, message, line: 0, column: 0, endLine: 0, endColumn: 0 };
}

export function placedModuleErrors(
	placed: string[],
	entryPath: string,
	lazy: HashSet<string>,
): BoundaryRefusal[] {
	const errors: BoundaryRefusal[] = [];
	for (const path of placed) {
		if (path == entryPath) {
			const message = `'${path}' is the entry module and has @wasm functions: `
				+ "the entry's top-level code would run again in wasm, "
				+ "so move them into a module it imports";
			errors.push(unlocated(path, "entry-module", message));
		}
		if (lazy.has(path)) {
			const message = `'${path}' has @wasm functions but is loaded lazily `
				+ "with import(): a module with @wasm functions must be imported "
				+ "statically";
			errors.push(unlocated(path, "lazy-module", message));
		}
	}
	return errors;
}

export function placedImportErrors(
	importerPath: string,
	imports: ImportEntry[],
	placed: string[],
): BoundaryRefusal[] {
	const errors: BoundaryRefusal[] = [];
	for (const imp of imports) {
		if (!placed.includes(imp.sourcePath) || !imp.names.includes("*")) continue;
		const message = `'${importerPath}' imports '*' from '${imp.sourcePath}', `
			+ "which has @wasm functions: a namespace import is not supported "
			+ "there, import the functions by name";
		errors.push(unlocated(importerPath, "namespace-import", message));
	}
	return errors;
}

function wasmOwnedClass(t: Type | null, handles: Symbol[]): Symbol | null {
	if (t == null) return null;
	const handle = peelThrough(t!, PEEL_ALIAS);
	if (handle == null || !isHandleType(handle!)) return null;
	const target = handleTarget(handle!);
	if (target == null || target!.sym == null || !handles.includes(target!.sym!)) return null;
	if (getBuiltinKind(target!) == BuiltinKind.FfiVecBox) return null;
	return target!.sym!;
}

function isHandleRead(node: Node, handles: Symbol[]): boolean {
	if (node.kind != NodeKind.MemberExpr) return false;
	const d = node.data as MemberExprData;
	if (d.property != "value" && d.property != "take" && d.property != "ptr") {
		return false;
	}
	const t = d.object.nodeType;
	if (t == null) return false;
	const handle = peelThrough(t!, PEEL_ALIAS);
	if (handle == null || !isHandleType(handle!)) return false;
	const target = handleTarget(handle!);
	return target != null && target!.sym != null && handles.includes(target!.sym!);
}

function ownedValueCall(node: Node, handles: Symbol[]): Symbol | null {
	if (node.kind != NodeKind.CallExpr) return null;
	const d = node.data as CallExprData;
	if (d.arguments.length != 0 || d.callee.kind != NodeKind.MemberExpr) return null;
	const m = d.callee.data as MemberExprData;
	if (m.property != "value") return null;
	return wasmOwnedClass(m.object.nodeType, handles);
}

function isAssignTarget(parent: Node, child: Node): boolean {
	if (parent.kind == NodeKind.BinaryExpr) {
		const b = parent.data as BinaryExprData;
		return b.left == child && isAssignOp(b.operator);
	}
	if (parent.kind == NodeKind.UpdateExpr) {
		return (parent.data as UpdateExprData).updateArg == child;
	}
	return false;
}

function isCallee(parent: Node, child: Node): boolean {
	return parent.kind == NodeKind.CallExpr && (parent.data as CallExprData).callee == child;
}

function isHiddenDeref(parent: Node, child: Node): boolean {
	return parent.kind == NodeKind.HiddenDeref && (parent.data as HiddenDerefData).expr == child;
}

function writesThroughCopy(member: Node, above: Node[]): boolean {
	const t = member.nodeType;
	if (t != null && peelThrough(t!, PEEL_ALIAS)?.kind == TypeKind.String) return false;
	let child = member;
	for (let i = above.length - 1; i >= 0; i -= 1) {
		const parent = above[i];
		if (isAssignTarget(parent, child) || isCallee(parent, child)) return true;
		const extends_ = (parent.kind == NodeKind.MemberExpr
			&& (parent.data as MemberExprData).object == child)
			|| (parent.kind == NodeKind.ArrayAccess
				&& (parent.data as ArrayAccessData).array == child)
			|| isHiddenDeref(parent, child);
		if (!extends_) return false;
		child = parent;
	}
	return false;
}

interface MemberScan {
	path: string;
	handles: Symbol[];
	inWasm: Node[];
	uses: MemberUse[];
	errors: BoundaryRefusal[];
}

function refuseAtNode(s: MemberScan, node: Node, code: string, message: string): void {
	const at = node.location;
	s.errors.push({
		file: s.path,
		code,
		message,
		line: at.line,
		column: at.column,
		endLine: at.line,
		endColumn: at.column,
	});
}

function noteUse(
	s: MemberScan,
	cls: Symbol,
	member: Node,
	access: MemberAccess,
	method: Symbol | null,
	site: Node | null,
	receiver: Node | null,
): void {
	const property = (member.data as MemberExprData).property;
	const jsName = method != null ? jsMethodMemberName(property, method) : property;
	s.uses.push({
		classSym: cls,
		property,
		jsName,
		access,
		method,
		valueType: method != null ? null : member.nodeType,
		file: s.path,
		at: member.location,
		site,
		receiver,
	});
}

function memberUseAt(s: MemberScan, cls: Symbol, valueCall: Node, scope: Node[]): void {
	let call = valueCall;
	const above = scope.slice(0);
	while (above.length > 0 && isHiddenDeref(above[above.length - 1], call)) {
		call = above.pop()!;
	}
	const parent = above.length > 0 ? above[above.length - 1] : null;
	const shown = cls.name;
	if (parent == null || parent.kind != NodeKind.MemberExpr
			|| (parent.data as MemberExprData).object != call) {
		refuseAtNode(
			s,
			call,
			"handle-read",
			`Handle<${shown}>.value() reads a wasm-owned object, which the JS side `
				+ `reaches only through its members: call a method or read or write a `
				+ `field as h.value().member, or pass the handle to a @wasm function`,
		);
		return;
	}
	const member = parent!;
	const grand = above.length > 1 ? above[above.length - 2] : null;
	const handle = ((valueCall.data as CallExprData).callee.data as MemberExprData).object;
	if (grand != null && isCallee(grand!, member)) {
		const method = grand!.resolvedSym ?? member.resolvedSym;
		if (method == null || method!.symbolKind != SymbolKind.Function) {
			refuseAtNode(s, member, "handle-member", `'${(member.data as MemberExprData).property}' of `
				+ `wasm-owned ${shown} is not a method of it`);
			return;
		}
		noteUse(s, cls, member, MemberAccess.Call, method, grand!, handle);
		return;
	}
	if (grand != null && isAssignTarget(grand!, member)) {
		const plain = grand!.kind == NodeKind.BinaryExpr
			&& (grand!.data as BinaryExprData).operator == "=";
		const statement = above.length > 2 && above[above.length - 3].kind == NodeKind.ExprStmt;
		if (!plain) noteUse(s, cls, member, MemberAccess.Get, null, null, null);
		const direct = plain && statement;
		noteUse(s, cls, member, MemberAccess.Set, null, direct ? grand! : null, direct ? handle : null);
		return;
	}
	if (writesThroughCopy(member, above.slice(0, above.length - 1))) {
		const field = (member.data as MemberExprData).property;
		refuseAtNode(
			s,
			member,
			"handle-copy-write",
			`h.value().${field} is a copy of the field '${field}' of wasm-owned `
				+ `${shown}, so a write or a method call through it would not reach `
				+ `the object: call a method of ${shown} that does it`,
		);
		return;
	}
	noteUse(s, cls, member, MemberAccess.Get, null, member, handle);
}

function handleMade(node: Node, handles: Symbol[]): Symbol | null {
	if (node.kind != NodeKind.CallExpr) return null;
	const d = node.data as CallExprData;
	if (d.callee.kind != NodeKind.MemberExpr) return null;
	const how = (d.callee.data as MemberExprData).property;
	if (how != "retain" && how != "borrow" && how != "at") return null;
	return wasmOwnedClass(node.nodeType, handles);
}

function constructionAt(s: MemberScan, cls: Symbol, call: Node): void {
	const d = call.data as CallExprData;
	const how = (d.callee.data as MemberExprData).property;
	let made = d.arguments.length == 1 ? d.arguments[0] : null;
	while (made != null && made!.kind == NodeKind.HiddenStdConv) {
		made = (made!.data as HiddenStdConvData).convExpr;
	}
	if (how == "retain" && made != null && made!.kind == NodeKind.NewExpr
			&& made!.resolvedSym != null) {
		s.uses.push({
			classSym: cls,
			property: "constructor",
			jsName: "new",
			access: MemberAccess.New,
			method: made!.resolvedSym,
			valueType: null,
			file: s.path,
			at: made!.location,
			site: made!,
			receiver: null,
		});
		return;
	}
	refuseAtNode(
		s,
		call,
		"handle-make",
		`Handle.${how}(…) of ${cls.name}, which lives in wasm: the JS side makes `
			+ `a Handle<${cls.name}> only as Handle.retain(new ${cls.name}(…)), which `
			+ "builds the object in wasm, or takes it from a @wasm function",
	);
}

function scanMembers(s: MemberScan, node: Node, above: Node[]): void {
	if (s.inWasm.includes(node)) return;
	const cls = ownedValueCall(node, s.handles);
	const made = cls == null ? handleMade(node, s.handles) : null;
	if (cls != null) {
		memberUseAt(s, cls!, node, above);
	} else if (made != null) {
		constructionAt(s, made!, node);
	} else if (isHandleRead(node, s.handles) && !(above.length > 0
			&& isCallee(above[above.length - 1], node)
			&& ownedValueCall(above[above.length - 1], s.handles) != null)) {
		const d = node.data as MemberExprData;
		const shown = typeDisplayName(d.object.nodeType!);
		refuseAtNode(s, node, "handle-read", `${shown} reads a wasm-owned handle: `
			+ "pass it to a @wasm function");
	}
	above.push(node);
	forEachChild(node, (child: Node): void => {
		scanMembers(s, child, above);
	});
	above.pop();
}

export function placedMemberUses(
	handles: Symbol[],
	path: string,
	program: Node,
	inWasm: Node[],
	uses: MemberUse[],
): BoundaryRefusal[] {
	const s: MemberScan = { path, handles, inWasm, uses, errors: [] };
	if (handles.length == 0) return s.errors;
	for (const stmt of (program.data as ProgramData).programStmts) {
		scanMembers(s, stmt, []);
	}
	return s.errors;
}
