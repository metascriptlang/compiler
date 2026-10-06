// @stdout: 6 9 3 0
// @xfail(raiser): the Raiser VM has no rest parameters ('cannot compile node kind SpreadExpr at comptime')
// note: a rest parameter reaches the parent's rest parameter whole, through an explicit `super(...xs)` and through the constructor a subclass without one inherits; an empty rest stays empty. Same output on C and JS.
class Many {
	total: int32 = 0;
	constructor(...xs: int32[]) { for (const x of xs) { this.total += x; } }
}
class Spread extends Many { constructor(...xs: int32[]) { super(...xs); } }
class Inherits extends Many { }

console.log(`${new Spread(1, 2, 3).total} ${new Many(4, 5).total} ${new Inherits(1, 2).total} ${new Inherits().total}`);
