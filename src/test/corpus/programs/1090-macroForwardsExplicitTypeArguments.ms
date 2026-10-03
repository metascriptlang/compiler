// @stdout: 2 2 7 4 0
// @exit: 0
// note: a macro that returns a call to another function keeps the explicit type arguments of the call it was given. The forwarded calls below are `make<int32>(4)`, an extension call `holder.build<int32>()`, the same two under `try`, and `new Cell<int32>()`; the function they are passed to takes a generic `Result<U, int32>` or a `Cell<U>`, or an int32 after `try`, so nothing but the written `<int32>` can bind T. A macro result used to lose that argument and every program here failed with `cannot instantiate: 'T'`.

import { Node, NodeKind } from "std/meta";

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

class Holder { seed: int32 = 4; }
class Cell<T> { items: T[] = []; }

function make<T>(code: int32): Result<T, int32> { return Result.err(code); }
function build<T>(this holder: Holder): Result<T, int32> { return Result.err(holder.seed); }
function resultCode<U>(result: Result<U, int32>): int32 { return result.ok ? 1 : 2; }
function valueCode(value: int32): int32 { return value; }
function cellCode<U>(cell: Cell<U>): int32 { return cell.items.length; }

function viaTry(): Result<int32, int32> {
	return Result.ok(forwardValue(try make<int32>(7)));
}

function viaExtensionTry(holder: Holder): Result<int32, int32> {
	return Result.ok(forwardValue(try holder.build<int32>()));
}

function main(): void {
	const holder = new Holder();
	const first = forwardResult(make<int32>(4));
	const second = forwardResult(holder.build<int32>());
	const third = viaTry();
	const fourth = viaExtensionTry(holder);
	const fifth = forwardCell(new Cell<int32>());
	console.log(`${first} ${second} ${third.ok ? 0 : third.error} ${fourth.ok ? 0 : fourth.error} ${fifth}`);
}
main();
