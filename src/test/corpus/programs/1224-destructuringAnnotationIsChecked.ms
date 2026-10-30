// @stdout: a 2 4 5 1 2
interface Src { x: string; y: int32; }
const src: Src = { x: "a", y: 2 };
const { x: v }: Src = src;
const { y = 7 }: { y: int32 } = { y: 2 };

function make(): { x: int32 } { return { x: 4 }; }
const { x }: { x: int32 } = make();
const { z }: { z: int32 } = { z: 5 };
const pair: [int32, int32] = [1, 2];
const [a, b]: [int32, int32] = pair;
console.log(v, y, x, z, a, b);
