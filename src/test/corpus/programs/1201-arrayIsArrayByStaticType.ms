// @stdout: true false false true false
// @stdout: true
class Bag {
	items: string[] = [];
}
const xs = [1, 2];
const nested = [["a"], ["b"]];
const words: string[] = [];
console.log(`${Array.isArray(xs)} ${Array.isArray("s")} ${Array.isArray({ a: 1 })} ${Array.isArray(nested)} ${Array.isArray(new Bag())}`);
console.log(`${Array.isArray(new Bag().items) && Array.isArray(words)}`);
