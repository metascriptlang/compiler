// note: an object literal passed to a sink constructor parameter of a union of records becomes that union's arm, as it does for a plain parameter and for a sink parameter of a function.
// @stdout: plain 1 a
// @stdout: sink 2 b
// @stdout: owned 3 c
// @stdout: owned holder 4
type V = { v: int32 };
type W = { w: string };
type D = V | W;
class Plain { data: D; constructor(data: D) { this.data = data; } }
class Sunk { data: D; constructor(sink data: D) { this.data = data; } }
class Held { data: Owned<D>; constructor(sink data: Owned<D>) { this.data = move data; } }
class Leaf { k: int32 = 4; }
type E = { leaf: Owned<Leaf> } | { none: boolean };
class Holder { data: Owned<E>; constructor(sink data: Owned<E>) { this.data = move data; } }
console.log("plain", (new Plain({ v: 1 }).data as V).v, (new Plain({ w: "a" }).data as W).w);
console.log("sink", (new Sunk({ v: 2 }).data as V).v, (new Sunk({ w: "b" }).data as W).w);
console.log("owned", (new Held({ v: 3 }).data as V).v, (new Held({ w: "c" }).data as W).w);
console.log("owned holder", (new Holder({ leaf: new Leaf() }).data as { leaf: Owned<Leaf> }).leaf.k);
