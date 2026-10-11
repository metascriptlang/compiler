// @stdout: swap=[bc][bc] clamp=[ab][ef][ab] rest=[cdef][] wide=[éll][😀x][héllo😀]
// note: `substring` clamps each index into the string, treating a negative one as 0 and one past the end as the length, swaps them when start is after end, and takes the end as the length when it is omitted; positions count UTF-16 units as in TS, so non-ASCII text cuts at the same places.

const s = "abcdef";
const swap = `swap=[${s.substring(1, 3)}][${s.substring(3, 1)}]`;
const clamp = `clamp=[${s.substring(-2, 2)}][${s.substring(4, 99)}][${s.substring(2, -1)}]`;
const rest = `rest=[${s.substring(2)}][${"".substring(0, 5)}]`;
const w = "héllo😀x";
const wide = `wide=[${w.substring(1, 4)}][${w.substring(5)}][${w.substring(7, 0)}]`;
console.log(`${swap} ${clamp} ${rest} ${wide}`);
