// @stdout: 2 c d c e
const fields: string[] = ["a", "b", "c", "d", "e"];
const at = fields.indexOf("c");
const n = 1;
let last = "";
for (let i = 0; i < 2; i += 1) { last = fields[i + 3]; }
console.log(at, fields[at], fields[at + 1], fields[n + 1], last);
