// @stdout: t:f 5 f 4 f:t 6 3 true
// note: a `Promise<number> | null` slot receives a `.then` result, an async call and null: it compares null and non-null at run time and is read back through the narrowed slot, on a field, a local and an array element.

async function f(): Promise<number> { return 4; }
class H { p: Promise<number> | null = null; }

const out: string[] = [];
function nn(x: Promise<number> | null): string { return `${x === null ? "t" : "f"}:${x != null ? "t" : "f"}`; }

const base = new Promise<number>((res) => { res(3); });
const h = new H();
out.push(nn(h.p));
h.p = base.then((x: number) => x + 2);
out.push(`${await (h.p as Promise<number>)}`);
h.p = f();
out.push(h.p === null ? "t" : "f");
if (h.p !== null) out.push(`${await h.p}`);
h.p = null;

let q: Promise<number> | null = base.then((x: number) => x * 2);
out.push(nn(q));
if (q != null) out.push(`${await q}`);
q = null;

const arr: (Promise<number> | null)[] = [null, base];
const last = arr[1];
if (arr[0] === null && last !== null) out.push(`${await last}`);
console.log(`${out.join(" ")} ${q === null}`);
