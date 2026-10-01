// @xfail(san): module-level uint8[] is never destroyed at exit, card 2026-10-01-globals-never-destroyed-at-exit
// @stdout: byte views 4 120 AxxxB xxxx

const source = "x".repeat(4);
const view = source.asBytes();
const copy = view.slice(0, view.length);
copy[0] = 65;
copy.push(66);
console.log(`byte views ${view.length} ${view[0]} ${copy.asString()} ${source}`);
