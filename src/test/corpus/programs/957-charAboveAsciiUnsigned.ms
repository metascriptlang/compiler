// @stdout: 195 195 195 195 | true false true false | true 196 | 97.5 99
// note: a char holds 0..255 on every backend, so a byte of 0x80 or more compares above ASCII and widens to its unsigned value (char-unsigned: C emitted a signed `char`, which read 0xC3 as -61).

function firstByte(s: string): char { return s.byteAt(0) as char; }
function lower(c: char, d: char): boolean { return c < d; }

const hi = firstByte("é");
const a = 97 as char;
console.log(`${hi as int32} ${hi as number} ${hi as uint32} ${hi as int64} | ${hi > a} ${hi < a} ${hi >= (195 as char)} ${lower(hi, a)} | ${[hi, a][0] > [hi, a][1]} ${(hi as int32) + 1} | ${((a as number) + (hi as number) - 195) + 0.5} ${(a as int32) + (firstByte("\x02") as int32)}`);
