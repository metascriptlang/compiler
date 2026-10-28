// @stdout: 8 abc 123 6
// @stdout: 4 b
const total = [{ a: 3 }, { a: 5 }].reduce((s, x) => s + x.a, 0);
const letters = ["a", "b", "c"].reduce((s, w) => s + w, "");
const joined = [1, 2, 3].reduce((s, x) => `${s}${x}`, "");
const sum = [1, 2, 3].reduce((a, b) => a + b);
console.log(total, letters, joined, sum);
const longest = ["aa", "b", "cccc"].reduce((best, w, i) => (w.length > best ? w.length : best), 0);
const second = ["a", "b"].reduce((acc, w, i) => (i == 1 ? w : acc), "");
console.log(longest, second);
