// Parity program — a top-level for-of keeps its element after the loop body replaces the slot
// it came from, and refuses a body that changes the array length.
//
// @stdout: a,b,c|zz,b,c|caught
// @exit: 0

const ps = "a b c".split(" ");
const seen: string[] = [];
for (const w of ps) {
	ps[0] = "zz";
	seen.push(w);
}
let caught = "";
try {
	for (const w of ps) { ps.push(w); }
} catch (e) { caught = "caught"; }
console.log([seen.join(","), ps.slice(0, 3).join(","), caught].join("|"));
