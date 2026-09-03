type IntFn = (n: int32) => int32;

interface Slot { cb: IntFn; }

function seed(n: int32): int32 { return n; }

function exprBody(): int32 {
    let f: IntFn = null as unknown as IntFn;
    f = (n: int32) => n * 2;
    return f(7);
}

function blockBody(): int32 {
    let f: IntFn = null as unknown as IntFn;
    f = (n: int32) => { return n + 1; };
    return f(7);
}

function capturing(): int32 {
    const base = 10;
    let f: IntFn = null as unknown as IntFn;
    f = (n: int32) => n + base;
    return f(7);
}

function reassignTwice(): int32 {
    const base = 100;
    let f: IntFn = (n: int32) => n;
    f = (n: int32) => n + base;
    f = (n: int32) => n - base;
    return f(7);
}

function fieldSlot(): int32 {
    const s: Slot = { cb: (n: int32) => n };
    s.cb = (n: int32) => n * 3;
    return s.cb(7);
}

function loopReassign(): int32 {
    let total = 0;
    let f: IntFn = null as unknown as IntFn;
    for (const i of [0, 1, 2]) {
        const step = i;
        f = (n: int32) => n + step;
        total = total + f(10);
    }
    return total;
}

function elementSlot(): int32 {
    const fns: IntFn[] = [(n: int32) => n];
    fns[0] = (n: int32) => n * 5;
    return fns[0](7);
}

function fromVariable(): int32 {
    const g: IntFn = (n: int32) => n * 4;
    let f: IntFn = null as unknown as IntFn;
    f = g;
    return f(7);
}

function fromNamed(): int32 {
    let f: IntFn = null as unknown as IntFn;
    f = seed;
    return f(7);
}

function main(): void {
    console.log(exprBody());
    console.log(blockBody());
    console.log(capturing());
    console.log(reassignTwice());
    console.log(fieldSlot());
    console.log(loopReassign());
    console.log(elementSlot());
    console.log(fromVariable());
    console.log(fromNamed());
}

main();
