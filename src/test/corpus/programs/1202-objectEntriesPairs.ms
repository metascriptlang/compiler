// @stdout: a=1,b=2|2
// @stdout: x:11,y:12
// @stdout: s+x,t+y
class P {
	x: int32 = 1;
	y: int32 = 2;
}
const o = { a: 1, b: 2 };
const flat: string[] = [];
for (const [k, v] of Object.entries(o)) flat.push(`${k}=${v}`);
console.log(`${flat.join(",")}|${Object.entries(o).length}`);
const shifted: string[] = [];
for (const [k, v] of Object.entries(new P())) shifted.push(`${k}:${v + 10}`);
console.log(shifted.join(","));
const m = { s: "x", t: "y" };
console.log(Object.entries(m).map(([k, v]) => `${k}+${v}`).join(","));
