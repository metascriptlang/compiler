interface RBox { n: number; }

function throughRef(arr: uint8[]): void { arr[0] = 7; }
function throughSpan(s: Span<uint8>): void { s[0] = 8; }
function throughIface(b: RBox): void { b.n = 9; }
function rebindScalar(n: number): number { n = 5; return n; }
function rebindVec(a: Vec<uint8>): number { a = [4, 4]; return a[0]; }

const r: uint8[] = [1, 2];
throughRef(r);
console.log("ref=" + r[0].toString());
const sp: uint8[] = [1, 2];
throughSpan(sp);
console.log("span=" + sp[0].toString());
const bx: RBox = { n: 1 };
throughIface(bx);
console.log("iface=" + bx.n.toString());
console.log("scalar=" + rebindScalar(1).toString());
const vv: Vec<uint8> = [1, 2];
console.log("rebind=" + rebindVec(vv).toString() + "," + vv[0].toString());
