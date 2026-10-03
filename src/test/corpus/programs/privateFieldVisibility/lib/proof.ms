export struct Account { address: uint64; }
export struct Signer { private account: Account; }
export function signer(a: Account): Signer { return { account: a }; }
export function address(this s: Signer): uint64 { return s.account.address; }

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
