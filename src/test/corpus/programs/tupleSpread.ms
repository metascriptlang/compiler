// @stdout: rest: 8
// @stdout: rest of three: 6
// @stdout: first: 5 7,8,1,2,3
// @stdout: last: 1,2,3,7,8
// @stdout: widened: 7,8
// @stdout: triple: a,p,q,r,b
// @stdout: twice: s,t,a,p,q,r,b,s,t
// @stdout: inferred: 7,8
function restA(d: int32, ...xs: int32[]): int32 { return xs.length > 0 ? xs[xs.length - 1] : d; }
function words(): [string, string, string] { console.log("words"); return ["p", "q", "r"]; }
function run(): void {
	const t: [int32, int32] = [7, 8];
	console.log("rest: " + restA(0, ...t).toString());
	const t3: [int32, int32, int32] = [4, 5, 6];
	console.log("rest of three: " + restA(0, ...t3).toString());
	const arr: int32[] = [1, 2, 3];
	const a3 = [...t, ...arr];
	console.log("first: " + a3.length.toString() + " " + a3.join(","));
	const a4: int32[] = [...arr, ...t];
	console.log("last: " + a4.join(","));
	const wide: int64[] = [...t];
	console.log("widened: " + wide.join(","));
	const all: string[] = ["a", ...words(), "b"];
	console.log("triple: " + all.join(","));
	const pair: [string, string] = ["s", "t"];
	const twice: string[] = [...pair, ...all, ...pair];
	console.log("twice: " + twice.join(","));
	const inferred = [...t];
	console.log("inferred: " + inferred.join(","));
}
run();
