// @stdout: 9 0 3 7 abc z 15
// note: a rest parameter is lent, not sunk, even to a constructor that owns its other parameters: the caller packs the trailing arguments and destroys the pack once. Locally, empty, inherited, through super(...xs), with a leading owned argument and with a pack built from a live array.
class Many {
	total: int32 = 0;
	constructor(...xs: int32[]) { for (const x of xs) { this.total += x; } }
}
class Joined {
	s: string = "";
	constructor(head: string, ...tail: string[]) { this.s = head; for (const t of tail) { this.s += t; } }
}
class Sub extends Many { }
class Spread extends Many { constructor(...xs: int32[]) { super(...xs); } }

const live: int32[] = [1, 2, 3, 4, 5];
console.log(`${new Many(4, 5).total} ${new Many().total} ${new Sub(1, 2).total} ${new Spread(3, 4).total} ${new Joined("a", "b", "c").s} ${new Joined("z").s} ${new Many(...live).total}`);
