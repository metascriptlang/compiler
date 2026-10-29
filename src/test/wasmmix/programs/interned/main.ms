// @stdout: 1286,857,857
import { hit, count } from "./internedWasm";

const names: string[] = ["alpha", "beta", "gamma"];
for (let i = 0; i < 3000; i = i + 1) { hit(names[(i % 7) % 3]); }
console.log(`${count(0)},${count(1)},${count(2)}`);
