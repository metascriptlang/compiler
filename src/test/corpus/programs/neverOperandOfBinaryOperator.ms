// @stdout: add=add sub=sub mul=mul eq=eq lt=lt cat=cat left=left float=float
function fail(message: string): never { throw new Error(message); }
let out = "";
function probe(name: string, run: () => void): void {
	try { run(); } catch (e) { out += `${name}=${e.message} `; }
}
probe("add", () => { const n: int32 = 1 + fail("add"); console.log(n); });
probe("sub", () => { const n: int32 = 5 - fail("sub"); console.log(n); });
probe("mul", () => { const n: int32 = 2 * fail("mul"); console.log(n); });
probe("eq", () => { if (fail("eq") == 1) console.log("hit"); });
probe("lt", () => { if (1 < fail("lt")) console.log("hit"); });
probe("cat", () => { const s: string = "a" + fail("cat"); console.log(s); });
probe("left", () => { const n: int32 = fail("left") + 1; console.log(n); });
probe("float", () => { const x: float64 = 1.5 * fail("float"); console.log(x); });
console.log(out.trim().split(" ").join(" "));
