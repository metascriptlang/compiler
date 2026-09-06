// nim-guard: PARALOCK §2.1/I14 — typed Promise.all. The result array is a
// refcounted heap CELL (lean Ref<Array> rep: msAllocTyped + arrDestroyFn), and
// collect CONSUMES each input future's value (msFutureRead convention: move out,
// clear slot — ptr NULLed, string zeroed, struct box freed). Red signatures:
//   - result allocated bare malloc → decref reads garbage header (crash/DOUBLE-DESTROY)
//   - deep-copy collect without consume → element over-release or payload leak
//   - inline read of a BOXED struct future → heap overflow / garbage values
// An unread Promise.all result must be released by the future's valueDestructor.
// GUARD-BALANCE msNumberArrayPallCell
// GUARD-BALANCE msStringArrayPallCell
// GUARD-BALANCE UserArrayPallCell
// GUARD-BALANCE msRefArrayRefCell
// GUARD-BALANCE BoxI

async function fd(x: float64): Promise<float64> { return x * 2.0; }

struct User { name: string; }
async function fu(n: string): Promise<User> { return { name: n }; }

async function fs(n: string): Promise<string> { return n + "!"; }

interface BoxI { v: int32; }
async function fb(v: int32): Promise<BoxI> { return { v }; }

async function main() {
    const a = await Promise.all([fd(1.0), fd(2.0)]);
    const b = await Promise.all([fu("x"), fu("y")]);
    const c = await Promise.all([fs("s"), fs("t")]);
    const d = await Promise.all([fb(1), fb(2)]);
    if (a.length + b.length + c.length + d.length != 8) throw "GUARD RED: lengths";
    if (a[0] + a[1] != 6.0) throw "GUARD RED: double values";
    if (b[0].name != "x" || b[1].name != "y") throw "GUARD RED: struct values";
    if (c[0] != "s!" || c[1] != "t!") throw "GUARD RED: string values";
    if (d[0].v + d[1].v != 3) throw "GUARD RED: ref values";
    // (An UNREAD Promise.all result is released by the result future's
    // valueDestructor when the future is destroyed on the drain path — not
    // observable via the exit ledger: futures pending at exit are exit-slack
    // and msFuture itself is a ledger blind spot, destroyFn=NULL.)
    console.log("GUARD-OK");
}
await main();
