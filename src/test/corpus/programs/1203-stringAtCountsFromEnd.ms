// @stdout: c a b|none none none|c
const s = "abc";
const last = s.at(-1) ?? "none";
const first = s.at(0) ?? "none";
const second = s.at(-2) ?? "none";
const past = s.at(3) ?? "none";
const before = s.at(-4) ?? "none";
const empty = "".at(0) ?? "none";
const one = "c".at(-1) ?? "none";
console.log(`${last} ${first} ${second}|${past} ${before} ${empty}|${one}`);
