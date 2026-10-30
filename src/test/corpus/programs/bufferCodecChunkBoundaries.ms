// @stdout: 200:3173482845 63:2053735601 64:2249925301 64:2249925301 100:2883643643 199:1558607803
// @stdout: 200=300:1808255261 64=300:2031896437 100=300:2682448315
// @stdout: 300:2256159842 300:2256159842 300:2256159842 120:3610058099 300:2256159842 299:1405698114
// @stdout: 50=320:352025891 51=320:2997115966 52=320:1515794939 300=320:1688243810
function hexOf(n: number): string { let s = ""; for (let i = 0; i < n; i++) { const v = (i * 37 + 11) % 256; s += (v < 16 ? "0" : "") + v.toString(16); } return s; }
function sum(hex: string): string { let h: number = 0; for (let i = 0; i < hex.length; i++) h = (h * 31 + hex.charCodeAt(i)) % 4294967296; return (hex.length / 2).toString() + ":" + h.toString(); }
function brk(s: string, at: int32, ch: string): string { return s.slice(0, at) + ch + s.slice(at + 1); }
function ins(s: string, at: int32, ch: string): string { return s.slice(0, at) + ch + s.slice(at); }

const h = hexOf(200);
let out = "";
for (const bad of [-1, 126, 128, 129, 200, 399]) out += sum(Buffer.fromString(bad < 0 ? h : brk(h, bad, "g"), "hex").toHex()) + " ";
console.log(out.trim());
out = "";
for (const bad of [-1, 128, 200]) { const b = Buffer.alloc(300); b.fill(170, 0, 300); const n = b.write(bad < 0 ? h : brk(h, bad, "z"), 5, 290, "hex"); out += n.toString() + "=" + sum(b.toHex()) + " "; }
console.log(out.trim());
const raw = Buffer.alloc(300);
for (let i = 0; i < 300; i++) raw.fill((i * 53 + 7) % 256, i, i + 1);
const b64 = raw.toBase64();
out = "";
const at: int32[] = [-1, 150, 151, 160, 203, 399];
const ch: string[] = ["", " ", "*", "=", "\n", "="];
for (let i = 0; i < at.length; i++) out += sum(Buffer.fromString(at[i] < 0 ? b64 : ins(b64, at[i], ch[i]), "base64").toHex()) + " ";
console.log(out.trim());
out = "";
for (const lim of [50, 51, 52, 300]) { const b = Buffer.alloc(320); b.fill(170, 0, 320); const n = b.write(b64, 3, lim, "base64"); out += n.toString() + "=" + sum(b.toHex()) + " "; }
console.log(out.trim());
