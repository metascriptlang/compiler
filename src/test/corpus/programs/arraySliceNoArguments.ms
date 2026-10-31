// @stdout: 2 a b 1 | 3 1
// @stdout: 3 1 2 3 | 1 | 2 3 | 1 | 1
// @stdout: 0 2 3
struct P { x: int32; y: int32; }

function main(): void {
	const xs: string[] = ["a", "b"];
	const copy = xs.slice();
	copy.push("c");
	console.log(`${xs.length} ${xs.slice()[0]} ${xs.slice(1)[0]} ${xs.slice(1, 2).length} | ${copy.length} ${xs.slice(0, -1).length}`);
	const ns: number[] = [1, 2, 3];
	console.log(`${ns.slice().length} ${ns.slice().join(" ")} | ${ns.slice(-1).length} | ${ns.slice(1).join(" ")} | ${ns.slice(-2, -1).length} | ${ns.slice(1, 2).length}`);
	const ps: P[] = [{ x: 1, y: 2 }, { x: 3, y: 4 }];
	const pc = ps.slice();
	pc.push({ x: 5, y: 6 });
	const none: number[] = [];
	console.log(`${none.slice().length} ${ps.length} ${pc.length}`);
}
main();
