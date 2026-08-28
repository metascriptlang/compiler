async function fd(x: float64): Promise<float64> { return x * 2.0; }
async function fi(x: int32): Promise<int32> { return x + 10; }
async function fs(n: string): Promise<string> { return n + "@x"; }

interface Pt { x: int32; y: int32; }
async function fp(x: int32): Promise<Pt> { return { x, y: x * 2 }; }

struct Tag { label: string; n: int32; }
async function ft(l: string, n: int32): Promise<Tag> { return { label: l, n }; }

async function main() {
    const ds = await Promise.all([fd(1.0), fd(2.0), fd(3.0)]);
    console.log(ds.length);
    console.log(ds[0] + ds[1] + ds[2]);

    const ivals = await Promise.all([fi(1), fi(2)]);
    console.log(ivals[0] + ivals[1]);

    const ss = await Promise.all([fs("alice"), fs("bob")]);
    console.log(ss[0] + " " + ss[1]);

    const ps = await Promise.all([fp(1), fp(2), fp(3)]);
    console.log(ps[0].x + ps[1].y + ps[2].x);

    const ts = await Promise.all([ft("a", 1), ft("b", 2)]);
    console.log(ts[0].label + ts[1].label);
    console.log(ts[0].n + ts[1].n);

    const hs: Promise<float64>[] = [];
    for (let i = 0; i < 4; i++) { hs.push(fd(i as float64)); }
    const rs = await Promise.all(hs);
    let sum = 0.0;
    for (const r of rs) { sum += r; }
    console.log(sum);
}
await main();
