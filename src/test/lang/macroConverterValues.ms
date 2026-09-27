import { Node, NodeKind } from "std/meta";
import { MkNum, toThunk, mkImpl } from "./macroConverterFixture";

type ConvertedNumber = number;

converter toNumber(node: Node): ConvertedNumber {
	return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: 7 };
}
function invokeConverted(fn: MkNum): number { return fn(); }
function readConverted(value: number | null): number { return value == null ? -1 : value; }
function readConvertedSlot(value: { slot?: number | null }): number { return value.slot == null ? -1 : value.slot; }

test "macro converter values: imported function aliases resolve at declaration and call slots" {
	const fn: MkNum = <div/>;
	assert fn() == 7;
	assert invokeConverted(<span/>) == 7;
}

test "macro converter values: nullable and quote boundaries preserve the converted payload" {
	const plain: ConvertedNumber = <div/>;
	const nullable: number | null = <x/>;
	const quoted: number = quote { 1 + 1 };
	const quotedMaybe: number | null = quote { 1 };
	assert plain == 7;
	assert nullable == 7;
	assert quoted == 7;
	assert quotedMaybe == 7;
	assert readConverted(<x/>) == 7;
	assert readConverted(quote { 1 }) == 7;
	assert readConvertedSlot({ slot: <x/> }) == 7;
}

