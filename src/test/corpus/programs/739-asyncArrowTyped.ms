type IntFn = (x: int32) => Promise<int32>;

const g1: IntFn = async (x) => { return x; };
const g2: IntFn = async (x) => x;
const h1 = async (x: int32) => { return x + 1; };

async function use(f: IntFn): Promise<int32> { return await f(5); }

interface Handler { run: IntFn; }

async function main() {
    const r1 = await g1(7);
    console.log(r1);
    const r2 = await g2(7);
    console.log(r2);
    const r3 = await h1(7);
    console.log(r3);
    const r4 = await use(async (x) => { return x * 2; });
    console.log(r4);
    const r5 = await use(async (x) => x * 2);
    console.log(r5);
    const h: Handler = { run: async (x) => x * 3 };
    const r6 = await h.run(5);
    console.log(r6);
    const fns: IntFn[] = [];
    for (const k of [1, 2, 3]) {
        fns.push(async (x) => { return x + k; });
    }
    let s = 0;
    for (const f of fns) { const v = await f(10); s = s + v; }
    console.log(s);
}
await main();
