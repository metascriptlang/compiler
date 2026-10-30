// @stdout: s 1
// @stdout: s 2
// @stdout: t 3
const o: { "x": string; "a-b": int32 } = { x: "s", "a-b": 1 };
console.log(o.x, o["a-b"]);
const { x: w, y: ab }: { "x": string; "y": int32 } = { x: "s", y: 2 };
console.log(w, ab);
function make(): { "k"?: int32; "m n": int32 } { return { "m n": 3 }; }
const m = make();
console.log("t", m["m n"]);
