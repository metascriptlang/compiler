import { NodeKind, IdentifierData, createNodeAt, makeLoc, Node, childCount, SourceLocation, getType } from "std/meta";
import { declareWireShape } from "./macroWireFixture";

test "macro node variant fit: variant cast widens at a call argument" {
	const loc = makeLoc(1, 1);
	const n = createNodeAt(NodeKind.Identifier, { name: "x" } as IdentifierData, loc);
	assert n.kind == NodeKind.Identifier;
	const d = n.data as IdentifierData;
	assert d.name == "x";
}

test "macro node variant fit: the uncast literal still works" {
	const loc = makeLoc(2, 1);
	const n = createNodeAt(NodeKind.Identifier, { name: "z" }, loc);
	const d = n.data as IdentifierData;
	assert d.name == "z";
}

declareWireShape(0);

test "macro declaration wire: an empty interfaceExtends crosses the macro wire without a Nil walk" {
	const s: SplicedShape = { a: 5 };
	assert s.a === 5;
}

macro sourceIdentity(node: Node): Node { return node; }

function sourceElement<T>(values: T[], index: int32): T { return sourceIdentity(values[index]); }

macro sourceShape(node: Node): Node {
	let text = "";
	for (const outer of node.elements) {
		if (outer.kind === NodeKind.ArrayLiteral) {
			text = text + "[";
			for (const inner of outer.elements) {
				if (inner.kind !== NodeKind.ObjectLiteral) { error("nested source object required", inner); }
				text = text + childCount(inner).toString();
			}
			text = text + "]";
		} else {
			if (outer.kind !== NodeKind.ObjectLiteral) { error("source object required", outer); }
			text = text + childCount(outer).toString();
		}
	}
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: text };
}

test "macro source forms: generic indexing preserves the selected element" {
	const values: int32[] = [10, 20, 30];
	const words: string[] = ["left", "right"];
	assert sourceElement(values, 0) == 10;
	assert sourceElement(values, 1 + 1) == 30;
	assert sourceElement(words, 1) == "right";
}

test "macro source forms: wrapper stripping recurses without flattening nesting" {
	assert sourceShape([{ width: 1 }, { height: 2 }]) == "11";
	assert sourceShape([[{ width: 1 }], [{ height: 2, depth: 3 }]]) == "[1][2]";
}

function dbl(value: string): string { return "caller " + value; }

function inner(value: string): string { return "caller macro " + value; }

test "macro expansion identity: declaration-module symbols resist caller shadowing" {
	assert dbl("x") == "caller x";
	assert inner("y") == "caller macro y";
}

function triple(value: int32): int32 { return value * 3; }

macro tripled(node: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: node.line,
		column: node.column,
		callee: bindSym("triple"),
		arguments: [node],
	};
}

test "macro expansion identity: a same-module bound callee resists a block-local shadow" {
	assert tripled(14) == 42;
	{ const triple: int32 = 9; assert tripled(8) + triple == 33; }
}

function nodeLeaf(loc: SourceLocation): Node {
	return createNodeAt(NodeKind.NumberLiteral, { value: 42, isFloat: false, intVal: 42 as int64 }, loc);
}

function nodeBranch(loc: SourceLocation): Node { return nodeLeaf(loc); }

macro helperOperands(node: Node): Node {
	const loc: SourceLocation = { line: node.line, column: node.column };
	return { kind: NodeKind.BinaryExpr, line: node.line, column: node.column, operator: "+", left: nodeLeaf(loc), right: nodeLeaf(loc) };
}

macro sharedOperand(node: Node): Node {
	const loc: SourceLocation = { line: node.line, column: node.column };
	const operand = nodeLeaf(loc);
	return { kind: NodeKind.BinaryExpr, line: node.line, column: node.column, operator: "+", left: operand, right: operand };
}

macro transitiveOperands(node: Node): Node {
	const loc: SourceLocation = { line: node.line, column: node.column };
	return { kind: NodeKind.BinaryExpr, line: node.line, column: node.column, operator: "+", left: nodeBranch(loc), right: nodeBranch(loc) };
}

test "macro source forms: helper-built nodes retain operands across storage and call depth" {
	assert helperOperands(0) == 84;
	assert sharedOperand(0) == 84;
	assert transitiveOperands(0) == 84;
}

macro forwardResult(call: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: call.line,
		column: call.column,
		callee: { kind: NodeKind.Identifier, line: call.line, column: call.column, name: "resultCode" },
		arguments: [call],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro forwardValue(call: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: call.line,
		column: call.column,
		callee: { kind: NodeKind.Identifier, line: call.line, column: call.column, name: "valueCode" },
		arguments: [call],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro forwardCell(cell: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: cell.line,
		column: cell.column,
		callee: { kind: NodeKind.Identifier, line: cell.line, column: cell.column, name: "cellCode" },
		arguments: [cell],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

class ExplicitHolder { seed: int32 = 4; }
class ExplicitCell<T> { items: T[] = []; }

function explicitFailure<T>(code: int32): Result<T, int32> { return Result.err(code); }
function explicitBuild<T>(this holder: ExplicitHolder): Result<T, int32> { return Result.err(holder.seed); }
function resultCode<U>(result: Result<U, int32>): int32 { return result.ok ? 1 : 2; }
function valueCode(value: int32): int32 { return value; }
function cellCode<U>(cell: ExplicitCell<U>): int32 { return cell.items.length; }

function forwardedTry(): Result<int32, int32> {
	return Result.ok(forwardValue(try explicitFailure<int32>(7)));
}

function forwardedExtensionTry(holder: ExplicitHolder): Result<int32, int32> {
	return Result.ok(forwardValue(try holder.explicitBuild<int32>()));
}

test "macro source forms: the explicit type argument of a call a macro forwards is kept" {
	assert forwardResult(explicitFailure<int32>(4)) == 2;
}

test "macro source forms: the explicit type argument of an extension call a macro forwards is kept" {
	const holder = new ExplicitHolder();
	assert forwardResult(holder.explicitBuild<int32>()) == 2;
}

test "macro source forms: the explicit type argument of a try call a macro forwards is kept" {
	const failed = forwardedTry();
	assert !failed.ok;
	assert failed.error == 7;
}

test "macro source forms: the explicit type argument of a try extension call a macro forwards is kept" {
	const failed = forwardedExtensionTry(new ExplicitHolder());
	assert !failed.ok;
	assert failed.error == 4;
}

test "macro source forms: the explicit type argument of a new expression a macro forwards is kept" {
	assert forwardCell(new ExplicitCell<int32>()) == 0;
}

test "macro source forms: a new expression a macro forwards builds the instance a direct one builds" {
	const direct = new ExplicitCell<string>();
	direct.items.push("a");
	assert cellCode(direct) == 1;
	assert forwardCell(new ExplicitCell<string>()) == 0;
}

macro returnedCall(call: Node): Node { return call; }

macro readCallType(call: Node): Node {
	if (getType(call) == null) { error("the call carries no type", call); }
	return call;
}

function explicitArray<T>(length: int32): T[] { return [] as T[]; }
function explicitNested<T>(code: int32): Result<T[], int32> { return Result.err(code); }
function explicitMethodArray<T>(this holder: ExplicitHolder): T[] { return [] as T[]; }
function nestedCode<U>(result: Result<U[], int32>): int32 { return result.ok ? 1 : 2; }

function returnedTry(): Result<int32, int32> {
	return Result.ok(returnedCall(try explicitFailure<int32>(7)));
}

function readTry(): Result<int32, int32> {
	return Result.ok(readCallType(try explicitFailure<int32>(7)));
}

test "macro source forms: a call a macro returns itself keeps its explicit type argument" {
	const holder = new ExplicitHolder();
	assert returnedCall(explicitArray<int32>(4)).length == 0;
	assert resultCode(returnedCall(explicitFailure<int32>(4))) == 2;
	assert nestedCode(returnedCall(explicitNested<string>(5))) == 2;
	assert returnedCall(holder.explicitMethodArray<int32>()).length == 0;
	assert returnedCall(new ExplicitCell<int32>()).items.length == 0;
}

test "macro source forms: a try call a macro returns itself keeps its explicit type argument" {
	const failed = returnedTry();
	assert !failed.ok;
	assert failed.error == 7;
}

test "macro source forms: getType on a call with an explicit type argument answers its instantiated type" {
	const holder = new ExplicitHolder();
	assert readCallType(explicitArray<int32>(4)).length == 0;
	assert resultCode(readCallType(explicitFailure<int32>(4))) == 2;
	assert nestedCode(readCallType(explicitNested<string>(5))) == 2;
	assert readCallType(holder.explicitMethodArray<int32>()).length == 0;
	assert readCallType(new ExplicitCell<int32>()).items.length == 0;
	const failed = readTry();
	assert !failed.ok;
	assert failed.error == 7;
}

macro inheritTypeArgument(code: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: code.line,
		column: code.column,
		callee: bindSym("explicitFailure"),
		arguments: [code],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro ownTypeArgument(code: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		line: code.line,
		column: code.column,
		callee: bindSym("explicitFailure"),
		arguments: [code],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
		typeArg: "string",
	};
}

test "macro source forms: a call a macro returns without type arguments takes the ones written at the macro call" {
	assert resultCode(inheritTypeArgument<int32>(3)) == 2;
}

test "macro source forms: a call a macro builds with its own typeArg binds T from it" {
	assert resultCode(ownTypeArgument(3)) == 2;
}
