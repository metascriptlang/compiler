// @stdout: 6 9 3 0 105 209 300
// note: a rest parameter reaches the parent's rest parameter whole, through an explicit `super(...xs)` and through the constructor a subclass without one inherits; an empty rest stays empty. Same output on C, JS and the Raiser.
// variant: the rest after a leading parameter, forwarded explicitly and inherited two levels down.
class Many {
	total: int32 = 0;
	constructor(...xs: int32[]) { for (const x of xs) { this.total += x; } }
}
class Spread extends Many { constructor(...xs: int32[]) { super(...xs); } }
class Inherits extends Many { }

class Headed {
	total: int32 = 0;
	constructor(head: int32, ...xs: int32[]) { this.total = head * 100; for (const x of xs) { this.total += x; } }
}
class HeadedSpread extends Headed { constructor(head: int32, ...xs: int32[]) { super(head, ...xs); } }
class HeadedInherits extends Headed { }
class HeadedDeeper extends HeadedInherits { }

console.log(`${new Spread(1, 2, 3).total} ${new Many(4, 5).total} ${new Inherits(1, 2).total} ${new Inherits().total} ${new HeadedSpread(1, 2, 3).total} ${new HeadedDeeper(2, 4, 5).total} ${new HeadedDeeper(3).total}`);
