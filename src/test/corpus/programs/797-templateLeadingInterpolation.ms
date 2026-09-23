// @stdout: 31|31|2.50.5|truefalse|312|31z|[31]

// A template that opens on an interpolation concatenates: adjacent numeric
// interpolations are joined as text, never added.
const a: number = 3;
const b: number = 1;
const x: int32 = 3;
const y: int32 = 1;
const f: float64 = 2.5;
const g: float64 = 0.5;
const t: boolean = true;
const u: boolean = false;
const z: string = "z";
const parts: string[] = [`${a}${b}`, `${x}${y}`, `${f}${g}`, `${t}${u}`, `${a}${b}${x - y}`, `${a}${b}${z}`, `[${a}${b}]`];
console.log(parts.join("|"));
