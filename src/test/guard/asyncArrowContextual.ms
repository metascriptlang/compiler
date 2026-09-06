type IntFn = (x: int32) => Promise<int32>;

const g1: IntFn = async (x) => { return x; };
const g2: IntFn = async (x) => x;
const h1 = async (x: int32) => { return x + 1; };

async function use(f: IntFn): Promise<int32> { return await f(5); }

interface Handler { run: IntFn; }

async function main(): Promise<void> {
    const r1 = await g1(7);
    if (r1 != 7) { throw "GUARD RED: block-body arrow r1=" + r1; }
    const r2 = await g2(7);
    if (r2 != 7) { throw "GUARD RED: expr-body arrow r2=" + r2; }
    const r3 = await h1(7);
    if (r3 != 8) { throw "GUARD RED: inferred-slot arrow r3=" + r3; }
    const r4 = await use(async (x) => { return x * 2; });
    if (r4 != 10) { throw "GUARD RED: call-arg block-body arrow r4=" + r4; }
    const r5 = await use(async (x) => x * 2);
    if (r5 != 10) { throw "GUARD RED: call-arg expr-body arrow r5=" + r5; }
    const h: Handler = { run: async (x) => x * 3 };
    const r6 = await h.run(5);
    if (r6 != 15) { throw "GUARD RED: object-field arrow r6=" + r6; }
    const fns: IntFn[] = [];
    for (const k of [1, 2, 3]) {
        fns.push(async (x) => { return x + k; });
    }
    let s = 0;
    for (const f of fns) { const v = await f(10); s = s + v; }
    if (s != 36) { throw "GUARD RED: loop-captured arrows s=" + s; }
    const gaw: IntFn = async (x) => {
        const y = await g1(x);
        return y * 2;
    };
    const r7 = await gaw(20);
    if (r7 != 40) { throw "GUARD RED: await-inside-arrow r7=" + r7; }
    console.log("asyncArrowContextual ok");
}
await main();
