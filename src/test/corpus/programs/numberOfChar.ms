// @stdout: 65 10 0
// note: Number() of a char gives its code point, as Number("A".charCodeAt(0)) does in TS.

const letter: char = 65 as char;
const newline: char = 10 as char;
const nul: char = 0 as char;
console.log(`${Number(letter)} ${Number(newline)} ${Number(nul)}`);
