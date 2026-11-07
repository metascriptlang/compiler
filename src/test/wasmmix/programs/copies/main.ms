// @stdout: 3.5 2 hé! 8 false
// @stdout: 1 true
// @stdout: 3,-1.5,0
// @stdout: 0
// @stdout: true,false,true
// @stdout: 0
// @stdout: 65537
// @stdout: 43 0.5 1.5 2 1 40
// @stdout: 3 0.5
// @stdout: 3 0
import { moved, scaled, flags, total, grown, countTrue, Label } from "./copiesWasm";

const l: Label = { at: { x: 1.5, y: 2 }, text: "hé", count: 7, shown: true };
const m = moved(l, 2);
console.log(`${m.at.x} ${m.at.y} ${m.text} ${m.count} ${m.shown}`);
console.log(`${l.at.x - 0.5} ${l.shown}`);
const xs: Vec<float32> = [1.5, -0.75, 0];
console.log(scaled(xs, 2).join(","));
const none: Vec<float32> = [];
console.log(`${scaled(none, 2).length}`);
console.log(flags(3).join(","));
console.log(`${flags(0).length}`);
const us: Vec<uint16> = [65535, 1, 1];
console.log(`${total(us)}`);
const fs: Vec<float64> = [0.5, 1.5, 2];
const g = grown(fs, 1);
console.log(`${g.length} ${g[0]} ${g[1]} ${g[2]} ${g[3]} ${g[42]}`);
console.log(`${fs.length} ${fs[0]}`);
const bs: Vec<boolean> = [true, false, true, true];
const nobs: Vec<boolean> = [];
console.log(`${countTrue(bs)} ${countTrue(nobs)}`);
