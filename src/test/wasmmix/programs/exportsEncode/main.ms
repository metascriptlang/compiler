// @stdout: 5
// @stdout: 0
// @stdout: 15
import { size, weigh, Note } from "./exportsEncodeWasm";

console.log(`${size("héllo")}`);
console.log(`${size("")}`);
const n: Note = { text: "héllo", weight: 3 };
console.log(`${weigh(n)}`);
