import { Node, NodeKind } from "std/meta";

export struct Account { address: uint64; }
export struct Signer { private account: Account; }
export function signer(a: Account): Signer { return { account: a }; }
export function address(this s: Signer): uint64 { return s.account.address; }

export macro mint(value: Node): Node {
	return {
		kind: NodeKind.TypeAssertion, line: 0, column: 0,
		asExpr: { kind: NodeKind.ObjectLiteral, line: 0, column: 0, keys: ["account"], properties: [value] },
		asType: "Signer",
	};
}

export macro mintTwice(value: Node): Node {
	return {
		kind: NodeKind.CallExpr, line: 0, column: 0,
		callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "mint" },
		arguments: [value],
	};
}

export macro declareProof(value: Node): Node {
	return {
		kind: NodeKind.SpliceMany, line: 0, column: 0,
		spliceNodes: [{
			kind: NodeKind.VariableDecl, line: 0, column: 0,
			declName: "proof", declType: "Signer",
			initializer: { kind: NodeKind.ObjectLiteral, line: 0, column: 0, keys: ["account"], properties: [value] },
			declKind: 0, nameLocation: { line: 0, column: 0 },
		}],
	};
}

export template unwrapped(s: Signer): uint64 { return s.account.address; }

export struct Box<T> { private v: T; n: int32; }
export function box<T>(x: T): Box<T> { return { v: x, n: 1 }; }
export function unbox<T>(b: Box<T>): T { return b.v; }

export class Bag<T> {
	private items: T[] = [];
	add(x: T): int32 { this.items.push(x); return this.items.length; }
	static of(x: T): Bag<T> { const b = new Bag<T>(); b.items.push(x); return b; }
}

export class Counter {
	private hits: int32 = 0;
	hit(): int32 { this.hits += 1; const read = () => this.hits; return read(); }
	same(other: Counter): boolean { return other.hits == this.hits; }
}
