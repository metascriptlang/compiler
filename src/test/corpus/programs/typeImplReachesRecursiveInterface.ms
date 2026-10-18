// @stdout: Box=value,rule Pair=value,rule Shelf=rules Outer=box Rule=blocks unnamed=00000
// note: getTypeImpl and getType of an interface whose field reaches a recursive interface (itself, through another interface, through an array, one interface deeper) answer its fields and name the recursion at the recursive interface, where the build used to stop with "getTypeImpl: unnamed or alias type cycle (Ref)" on every backend.
import { Node, NodeKind, getType, getTypeImpl } from "std/meta";

interface Rule { blocks: Rule[] | null; }
interface Box { value: number; rule: Rule; }
interface Left { right: Right | null; }
interface Right { left: Left; }
interface Pair { value: number; rule: Left; }
interface Shelf { rules: Rule[]; }
interface Outer { box: Box; }

macro fields(x: Node): Node {
	const impl = getTypeImpl(x);
	if (impl == null || impl.kind != NodeKind.TypeObject) error("no implementation", x);
	return { kind: NodeKind.StringLiteral, line: x.line, column: x.column, value: impl.typExprFieldNames.join(",") };
}

macro unnamed(x: Node): Node {
	const pending: Node[] = [getTypeImpl(x)!, getType(x)!];
	let count = 0;
	while (pending.length > 0) {
		const n = pending.pop()!;
		if (n.kind == NodeKind.Identifier && (n.name == "<cycle>" || n.name == "")) count += 1;
		if (n.kind == NodeKind.TypeObject) for (const f of n.typExprFieldTypes) pending.push(f);
		if (n.kind == NodeKind.TypeUnion) for (const m of n.typExprMembers) pending.push(m);
		if (n.kind == NodeKind.TypeGeneric) for (const g of n.typExprArgs) pending.push(g);
		if (n.kind == NodeKind.TypeArray) pending.push(n.typExprElement);
	}
	return { kind: NodeKind.StringLiteral, line: x.line, column: x.column, value: `${count}` };
}

function main(): void {
	const rule: Rule = { blocks: null };
	const box: Box = { value: 1, rule };
	const pair: Pair = { value: 2, rule: { right: null } };
	const shelf: Shelf = { rules: [rule] };
	const outer: Outer = { box };
	console.log(`Box=${fields(box)} Pair=${fields(pair)} Shelf=${fields(shelf)} Outer=${fields(outer)} Rule=${fields(rule)} unnamed=${unnamed(box)}${unnamed(pair)}${unnamed(shelf)}${unnamed(outer)}${unnamed(rule)}`);
}

main();
