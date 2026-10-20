// @stdout: 1 2.5 s true
// @stdout: caught boom
// @exit: 0
// note: a never result held in an int, number, string or boolean slot has no value to move, whatever slot class it lands in.

function boom(): never { throw new Error("boom"); }
function intLocal(c: boolean): int32 { if (c) { const q: int32 = boom(); return q; } return 1; }
function floatLocal(c: boolean): number { if (c) { const q: number = boom(); return q; } return 2.5; }
function strLocal(c: boolean): string { if (c) { const q: string = boom(); return q; } return "s"; }
function boolArg(c: boolean): boolean { const take = (b: boolean): boolean => !b; return c ? take(boom()) : true; }
console.log(intLocal(false), floatLocal(false), strLocal(false), boolArg(false));
try { floatLocal(true); } catch (e) { console.log(`caught ${(e as Error).message}`); }
