// @stdout: cat abc
// @stdout: less false true
// @stdout: joined ab-c-ab
// @stdout: digits 3 1+2
// @stdout: halves 2 0.5+1.5
// note: a value whose type is a literal union is a value of the union's base type in every operator and container, on every backend: string unions concatenate and compare as strings, number unions add as numbers, through a parameter, an array join and an awaited promise.

type Word = "ab" | "c";
type Digit = 1 | 2;
type Half = 0.5 | 1.5;

function cat(x: Word, y: Word): string { return x + y; }
function less(x: Word, y: Word): boolean { return x < y; }

async function digit(big: boolean): Promise<Digit> { return big ? 2 : 1; }
async function half(big: boolean): Promise<Half> { return big ? 1.5 : 0.5; }

console.log("cat", cat("ab", "c"));
console.log("less", less("c", "ab"), less("ab", "c"));
const words: Word[] = ["ab", "c", "ab"];
console.log("joined", words.join("-"));
const ds: Digit[] = [await digit(false), await digit(true)];
console.log("digits", ds[0] + ds[1], ds.join("+"));
const hs: Half[] = [await half(false), await half(true)];
console.log("halves", hs[0] + hs[1], hs.join("+"));
