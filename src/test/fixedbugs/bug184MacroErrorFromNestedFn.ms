// bug184 — error() only reported from the macro body's own frame
//
// Symptom:    a macro that rejects input from a nested helper either lost the
//             diagnostic (helper returns void — the file compiled clean) or
//             failed with "expected an array, got value kind Object" (helper
//             returns Node[]).
// Root:       `tryRewriteCompileError` rewrote error(msg, node) into
//             `return { __compileError, message, line, column }`, so the abort
//             was a return from whatever function lexically contained the call.
//             A helper's return value either dropped the sentinel or handed it
//             to the caller in place of the declared type.
// Fix:        error(msg, loc) rewrites to a throw of a prefixed payload that
//             the VM intercepts AT the Throw opcode — halting before any
//             handler or frame can see it, the way Nim's opcNError →
//             stackTrace (vm.nim:2034) leaves rawExecute from any depth.
// Found by:   Neon arc STYLE_TABLE, {...props} expansion — the spread rejects
//             (map type, non-path base, children, nullable handler) all live in
//             one attribute-expanding helper.
import { compileToCWithStd } from "../helpers";

test "bug184: error() from a nested helper returning an array reports the message" {
	const c = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

macro pick(node: Node): Node {
	function keep(list: Node[]): Node[] {
		let out: Node[] = [];
		for (const a of list) {
			if (a.kind === NodeKind.StringLiteral) {
				error("a string argument is rejected here", a as Node);
				continue;
			}
			out.push(a);
		}
		return out;
	}
	const kids: Node[] = [node];
	const kept = keep(kids);
	console.log("kept=" + (kept.length as int32).toString());
	return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: 0, isFloat: false, intVal: 0, outOfRangeText: "", isBitPattern: false };
}

const v: int32 = pick("no");
console.log(v.toString());
`);
	assert !c.ok, "the macro must be rejected";
	assert c.error.contains("a string argument is rejected here"), "diagnostic must survive the helper: " + c.error;
	assert !c.error.contains("expected an array"), "the sentinel must not reach the caller: " + c.error;
}

test "bug184: error() from a nested helper returning void still reports" {
	const c = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

macro check(node: Node): Node {
	function reject(a: Node): void {
		error("rejected from a void helper", a as Node);
	}
	reject(node);
	console.log("helper returned");
	return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: 0, isFloat: false, intVal: 0, outOfRangeText: "", isBitPattern: false };
}

const v: int32 = check(1);
console.log(v.toString());
`);
	assert !c.ok, "the macro must be rejected";
	assert c.error.contains("rejected from a void helper"), "diagnostic must survive the helper: " + c.error;
}

test "bug184: error() halts the macro at the call, like opcNError leaves rawExecute" {
	const c = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

macro halting(node: Node): Node {
	function reject(a: Node): void {
		error("halt here", a as Node);
	}
	reject(node);
	console.log("__MUST_NOT_RUN__");
	return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: 0, isFloat: false, intVal: 0, outOfRangeText: "", isBitPattern: false };
}

const v: int32 = halting(1);
console.log(v.toString());
`);
	assert !c.ok, "the macro must be rejected";
	assert !c.error.contains("__MUST_NOT_RUN__"), "expansion must stop at the error: " + c.error;
}

test "bug184: error() from the macro body keeps reporting at the argument's location" {
	const c = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

macro direct(node: Node): Node {
	error("rejected from the macro body", node as Node);
	return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: 0, isFloat: false, intVal: 0, outOfRangeText: "", isBitPattern: false };
}

const v: int32 = direct(1);
console.log(v.toString());
`);
	assert !c.ok, "the macro must be rejected";
	assert c.error.contains("rejected from the macro body"), "body-frame diagnostic unchanged: " + c.error;
}

test "bug184: a try/catch in the macro body cannot swallow error()" {
	const c = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

macro guarded(node: Node): Node {
	function reject(a: Node): void {
		error("not swallowed", a as Node);
	}
	try {
		reject(node);
	} catch (e) {
		console.log("caught");
	}
	return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: 0, isFloat: false, intVal: 0, outOfRangeText: "", isBitPattern: false };
}

const v: int32 = guarded(1);
console.log(v.toString());
`);
	assert !c.ok, "the macro must be rejected";
	assert c.error.contains("not swallowed"), "error() is not an exception the author can catch: " + c.error;
}
