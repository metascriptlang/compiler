// An array built by a loop that pushes once per step keeps the push loop's result when the source grows, shrinks
// or a callback raises midway, for plain and counted elements; a filter and a body that reads the array it
// builds keep pushing (NIM-REF TR-41).
//
// @stdout: 2,4,6|1,2,3,11,12,13|1,2,3|ab-,cd-,ef-|boom 2|3,6,9|2,3|1,3,5|0|p1,p2,p3|x,x,y

class P { v: string; constructor(v: string) { this.v = v; } }

function doubled(): string { const a: int32[] = [1, 2, 3]; return a.values().map((x) => x * 2).toArray().join(","); }
function grown(): string { const a: int32[] = [1, 2, 3]; return a.values().map((x) => { if (a.length < 6) a.push(x + 10); return x; }).toArray().join(","); }
function shrunk(): string { const a: int32[] = [1, 2, 3, 4, 5]; return a.values().map((x) => { a.pop(); return x; }).toArray().join(","); }
function strings(): string {
	const a: string[] = ["ab", "cd"];
	return a.values().map((s) => { if (a.length < 3) a.push("ef"); return s + "-heap-string-long-enough-xx"; }).toArray().map((s) => s.slice(0, 3)).join(",");
}
function raised(): string {
	const out: int32[] = [];
	const a: int32[] = [1, 2, 3, 4];
	try {
		for (const x of a) {
			if (x == 3) throw new Error("boom");
			out.push(x * 10);
		}
	} catch (e) {
		return "boom " + String(out.length);
	}
	return "none";
}
function forOf(): string { const a: int32[] = [1, 2, 3]; const out: int32[] = []; for (const x of a) out.push(x * 3); return out.join(","); }
function filtered(): string { const a: int32[] = [1, 2, 3]; return a.values().filter((x) => x > 1).toArray().join(","); }
function readsOut(): string { const a: int32[] = [1, 2, 3]; const out: int32[] = []; for (const x of a) out.push(x + out.length); return out.join(","); }
function empty(): string { const a: int32[] = []; return String(a.values().map((x) => x + 1).toArray().length); }
function objects(): string { const a: int32[] = [1, 2, 3]; return a.values().map((x) => new P("p" + String(x))).toArray().map((p) => p.v).join(","); }
function raisedInChain(): string {
	const a: string[] = ["x", "x", "y", "z"];
	let seen = "";
	try {
		a.values().map((s) => { if (s == "z") throw new Error("z"); seen += s; return s; }).toArray();
	} catch (e) {
		return seen.split("").join(",");
	}
	return "none";
}
console.log([doubled(), grown(), shrunk(), strings(), raised(), forOf(), filtered(), readsOut(), empty(), objects(), raisedInChain()].join("|"));
