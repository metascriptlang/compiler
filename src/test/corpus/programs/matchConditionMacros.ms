// @stdout: 10 20|30 40 30 40|50 50|0 1 1|2:3
// @exit: 0

import { Node, NodeKind, createNodeAt } from "std/meta";

macro accepted(value: Node): Node {
	const one: Node = createNodeAt(NodeKind.NumberLiteral, {
		value: 1, isFloat: false, intVal: 1, outOfRangeText: "", isBitPattern: false,
	}, value.location);
	const yes: Node = createNodeAt(NodeKind.BooleanLiteral, { boolValue: true }, value.location);
	const no: Node = createNodeAt(NodeKind.BooleanLiteral, { boolValue: false }, value.location);
	const wildcard: Node = createNodeAt(NodeKind.Identifier, { name: "_" }, value.location);
	const hit: Node = createNodeAt(NodeKind.MatchCase, { casePatterns: [one], caseGuard: null, caseBody: yes }, value.location);
	const miss: Node = createNodeAt(NodeKind.MatchCase, { casePatterns: [wildcard], caseGuard: null, caseBody: no }, value.location);
	return createNodeAt(NodeKind.MatchExpr, { matchDisc: value, matchCases: [hit, miss] }, value.location);
}

function plain(value: int32): int32 {
	if (accepted(value)) { return 10; }
	return 20;
}

function generic<T>(value: T): int32 {
	if (!accepted(value)) { return 40; }
	return 30;
}

function normalGeneric<T>(value: T): int32 {
	if (match (value) { _ => true }) { return 50; }
	return 60;
}

let calls: int32 = 0;
function bump(): int32 { calls += 1; return 1; }
function guarded(enabled: boolean): int32 {
	if (enabled && accepted(bump())) { return 1; }
	return 0;
}

function macroLoop(): int32 {
	let i: int32 = 0;
	let sum: int32 = 0;
	do {
		i += 1;
		if (i == 1) { continue; }
		sum += i;
	} while (accepted(bump()) && (match (i) { 1 => true, _ => false }));
	return sum;
}

const output: string[] = [];
output.push(`${plain(1)} ${plain(2)}`);
output.push(`${generic<int32>(1)} ${generic<int32>(2)} ${generic<uint8>(1 as uint8)} ${generic<uint8>(2 as uint8)}`);
output.push(`${normalGeneric<int32>(1)} ${normalGeneric<string>("value")}`);
const empty: int32[] = [];
const skipped = guarded(empty.length > 0);
const taken = guarded(empty.length == 0);
output.push(`${skipped} ${taken} ${calls}`);
const loopSum = macroLoop();
output.push(`${loopSum}:${calls}`);
console.log(output.join("|"));
