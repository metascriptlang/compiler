// @stdout: 1 2 3 4 5 8 9 26 102
interface Inner { b: int32; c: int32; }
interface Outer { a: Inner; xs: int32[]; }
const o: Outer = { a: { b: 1, c: 2 }, xs: [3, 4] };

const { a: { b } } = o;
const { a: { c: renamed } } = o;
const { xs: [first] } = o;
const { xs: [, second] } = o;

const pairs: Inner[] = [{ b: 5, c: 6 }, { b: 7, c: 8 }];
const [{ b: p0 }, { c: p1 }] = pairs;

interface Opt { d: int32 | null; }
interface Holder { opt: Opt; }
const h: Holder = { opt: { d: null } };
const { opt: { d = 9 } } = h;

let sum = 0;
const items: Outer[] = [o, { a: { b: 10, c: 11 }, xs: [12] }];
for (const { a: { b: fb }, xs: [fx] } of items) sum += fb + fx;

function inner({ a: { b: pb, c: pc } }: Outer): int32 { return pb * 100 + pc; }

console.log(b, renamed, first, second, p0, p1, d, sum, inner(o));
