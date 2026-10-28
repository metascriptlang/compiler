// @stdout: 0 1 1 0
// note: a pointer assigned from two different calls and joined after a null test stays Ptr<T> | null, because the same pointee reaching the join from two sources is one alternative, for another pointee type and for a plain nullable struct reference too.

struct Node { n: int32; }
function noneVoid(): Ptr<void> | null { return null; }
function otherVoid(): Ptr<void> | null { return null; }
function noneInt(): Ptr<int32> | null { return null; }
function otherInt(): Ptr<int32> | null { return null; }
function noneNode(): Node | null { return null; }
function someNode(): Node | null { return { n: 7 }; }

function takeVoid(p: Ptr<void> | null): int32 { return p === null ? 0 : 1; }
function takeInt(p: Ptr<int32> | null): int32 { return p === null ? 0 : 1; }
function takeNode(p: Node | null): int32 { return p === null ? 0 : 1; }

let a: Ptr<void> | null = noneVoid();
if (a === null) { a = otherVoid(); }
let b: Ptr<int32> | null = noneInt();
if (b === null) { b = otherInt(); }
let c: Node | null = noneNode();
if (c === null) { c = someNode(); }
let d: Ptr<int32> | null = noneInt();
if (d === null) { d = otherInt(); }

const first = a !== null ? takeVoid(a) : takeVoid(null);
console.log(`${first} ${takeNode(c)} ${c !== null ? takeNode(c) : 0} ${b !== null ? takeInt(b) : takeInt(d)}`);
