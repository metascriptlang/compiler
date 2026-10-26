// @stdout: call=x1,ea local=x2,eb field=x3,ec cell=x4,k5 int=7,9 arr=2,0 drop=1,2
struct Wrap { label: string; }
class Holder { name: string | null = null; }
function get(n: int32): string | null { if (n > 0) { return "x" + n.toString(); } return null; }
function wrapOf(s: string): Wrap { return { label: s }; }
function nums(n: int32): int32[] | null { if (n > 0) { return [n, n]; } return null; }
function maybeInt(n: int32): int32 | null { if (n > 0) { return n; } return null; }

function viaCall(n: int32, s: string): string { return get(n) ?? "e" + s; }
function viaLocal(n: int32, s: string): string { const l = get(n); return l ?? "e" + s; }
function viaField(n: int32, s: string): string { const h = new Holder(); h.name = get(n); return h.name ?? "e" + s; }
function viaCell(n: int32, s: string): string { return get(n) ?? wrapOf("k" + s).label; }
function viaInt(n: int32): int32 { return maybeInt(n) ?? 9; }
function viaArr(n: int32): int32 { return (nums(n) ?? []).length; }
function dropOnly(n: int32): int32 { const l = get(n); return l == null ? 1 : 2; }

console.log(`call=${viaCall(1, "a")},${viaCall(0, "a")} local=${viaLocal(2, "b")},${viaLocal(0, "b")} field=${viaField(3, "c")},${viaField(0, "c")} cell=${viaCell(4, "5")},${viaCell(0, "5")} int=${viaInt(7)},${viaInt(0)} arr=${viaArr(1)},${viaArr(0)} drop=${dropOnly(0)},${dropOnly(1)}`);
