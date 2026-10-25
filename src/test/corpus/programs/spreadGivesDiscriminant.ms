// @stdout: string 30 20 40 7 | enum 30 1 | bool at 5 none | explicit 30
type Circle = { kind: "c"; r: number };
type Square = { kind: "s"; side: number };
type Shape = Circle | Square;
type Radius = { r: number };
enum K { C, S }
type KCircle = { kind: K.C; r: number };
type KShape = KCircle | { kind: K.S; side: number };
type Hit = { hit: true; at: number };
type Probe = Hit | { hit: false; reason: string };

function area(s: Shape): number { return s.kind === "c" ? s.r * 10 : s.side; }
function karea(s: KShape): number { return s.kind === K.C ? s.r * 10 : s.side; }
function show(p: Probe): string { return p.hit ? "at " + p.at : p.reason; }

const c: Circle = { kind: "c", r: 2 };
const sq: Square = { kind: "s", side: 7 };
const radius: Radius = { r: 4 };
const whole: Shape = { ...c };
const kc: KCircle = { kind: K.C, r: 2 };
const ks: KShape = { kind: K.S, side: 1 };
const h: Hit = { hit: true, at: 4 };
const miss: Probe = { hit: false, reason: "none" };
console.log("string " + area({ ...c, r: 3 }) + " " + area(whole) + " " + area({ kind: "c", ...radius }) + " " + area({ ...{ ...sq } }) + " | enum " + karea({ ...kc, r: 3 }) + " " + karea({ ...ks }) + " | bool " + show({ ...h, at: 5 }) + " " + show({ ...miss }) + " | explicit " + area({ ...c, kind: "c", r: 3 }));
