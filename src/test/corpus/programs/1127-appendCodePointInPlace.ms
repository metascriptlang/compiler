// @stdout: append-codepoint 0041 00e9 4e2d 1f600 | true | abcde true 6 true
import { fromCodePoint } from "std/core/string";

const cps = [0x41, 0xe9, 0x4e2d, 0x1f600];
let text = "";
for (const cp of cps) text += fromCodePoint(cp);
const back = [text == "Aé中\u{1f600}" ? "0041 00e9 4e2d 1f600" : text];

let built = "a";
built += fromCodePoint(0xe9);
built += fromCodePoint(0x4e2d);
built += fromCodePoint(0x1f600);

let ascii = "";
for (let i = 0; i < 5; i++) ascii += fromCodePoint(0x61 + i);
const before = ascii.slice(0, 5);
ascii += fromCodePoint(0x4e2d);

console.log("append-codepoint", back.join(" "), "|", built == "aé中\u{1f600}", "|", before, ascii == "abcde中", ascii.length, ascii.slice(5) == "中");
