import { Node, NodeKind, bindSym } from "std/meta";
import { Public as Alias, fromInt } from "./fixtures/macroOwnedOperandHidden";

function plain(): uint64 { return 7; }
function plainOne(value: uint64): uint64 { return value + 1; }
function identity<T>(value: T): T { return value; }
function genericPlain<T>(): int32 { return 4; }
function pick<E>(member: int32): Result<E, string> { return Result.ok(member as E); }
enum Op { First, Second }

macro replacement(): Node {
	return {
		kind: NodeKind.CallExpr,
		callee: bindSym("plain")!,
		arguments: [],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro replacementOne(value: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		callee: bindSym("plainOne")!,
		arguments: [value],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro owned(): Node {
	return {
		kind: NodeKind.CallExpr,
		callee: { kind: NodeKind.TypeGeneric, typExprBase: bindSym("genericPlain")!, typExprArgs: [getTypeArg()] },
		arguments: [],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro ownedPick(value: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		callee: { kind: NodeKind.TypeGeneric, typExprBase: bindSym("pick")!, typExprArgs: [getTypeArg()] },
		arguments: [value],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro ownedFromInt(value: Node): Node {
	return {
		kind: NodeKind.CallExpr,
		callee: { kind: NodeKind.TypeGeneric, typExprBase: bindSym("fromInt")!, typExprArgs: [getTypeArg()] },
		arguments: [value],
		isDirectCall: false,
		resolvedOverloadIdx: -1,
	};
}

macro forwarded(value: Node): Node { return value; }

test "a nongeneric replacement does not inherit the macro type argument" {
	assert replacement<int32>() == 7;
}

test "a replacement with a value argument does not inherit the macro type argument" {
	assert replacementOne<string>(8) == 9;
}

test "a forwarded call retains its own explicit type argument" {
	assert forwarded(identity<int32>(11)) == 11;
}

test "a forwarded call replaces a distinct macro type argument" {
	assert forwarded<uint64>(identity<int32>(13)) == 13;
}

test "a replacement callee binds the macro type argument as an owned operand" {
	assert owned<int32>() == 4;
}

test "an owned operand instantiates a callee that returns a generic result" {
	const picked = ownedPick<Op>(1);
	assert picked.ok;
}

test "an owned operand reaches a private type through an exported alias" {
	const made: Alias = ownedFromInt<Alias>(5);
	assert made.v == 5;
}
