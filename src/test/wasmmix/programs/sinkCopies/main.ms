// @stdout: 12 hello sink é reassigned
// @stdout: 18 copied at the call / copied at the call
// @stdout: round trip 😀
// @stdout: none some
// @stdout: 7 seven
// @stdout: 8 eight eight
// @stdout: 3 15
// @stdout: 2 3 1,2
// @stdout: 3 1,2,3
import { Note, stash, stashed, echo, echoMaybe, keepNote, keptNoteText, keepXs, keptSum } from "./sinkCopiesWasm";

let s = "hello sink é";
const len = stash(move s);
s = "reassigned";
console.log(`${len} ${stashed()} ${s}`);
const t = "copied at the call";
console.log(`${stash(t)} ${stashed()} / ${t}`);
console.log(echo("round trip 😀"));
console.log(`${echoMaybe(null)} ${echoMaybe("some")}`);

let n: Note = { id: 7, text: "seven" };
console.log(`${keepNote(move n)} ${keptNoteText()}`);
const m: Note = { id: 8, text: "eight" };
console.log(`${keepNote(m)} ${keptNoteText()} ${m.text}`);

let xs: Vec<int32> = [4, 5, 6];
console.log(`${keepXs(move xs)} ${keptSum()}`);
let ys: Vec<int32> = [1, 2];
console.log(`${keepXs(ys)} ${keptSum()} ${ys.join(",")}`);
ys.push(3);
console.log(`${keptSum()} ${ys.join(",")}`);
