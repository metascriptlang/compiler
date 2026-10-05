// @stdout: Vec<float64> g1 g2 2|float64[] g1 g2 3|Vec<int32> g1 g2 7|int32[] g1 g2 9|string[] s1 s2 a|joined 1.5,2 6,7
// note: an extension overloaded with a generic and a concrete receiver instantiates the generic one from either array shape, a value Vec<T> on a T[] receiver and a T[] on a Vec<T> receiver. Before, the overload kept T unbound and C called a function nobody emitted.
function onRef<T>(this arr: T[]): string { return "g1"; }
function onRef(this arr: string[]): string { return "s1"; }
function onVec<T>(this arr: Vec<T>): string { return "g2"; }
function onVec(this arr: Vec<string>): string { return "s2"; }
function lastOf<T>(this arr: T[]): T { return arr[arr.length - 1]; }
function lastOf(this arr: string[]): string { return arr[0]; }

function main(): void {
	let vf: Vec<float64> = [1.5, 2];
	const rf: float64[] = [2.5, 3];
	let vi: Vec<int32> = [6, 7];
	const ri: int32[] = [8, 9];
	const rs: string[] = ["a", "b"];
	const out: string[] = [];
	out.push(`Vec<float64> ${vf.onRef()} ${vf.onVec()} ${vf.lastOf()}`);
	out.push(`float64[] ${rf.onRef()} ${rf.onVec()} ${rf.lastOf()}`);
	out.push(`Vec<int32> ${vi.onRef()} ${vi.onVec()} ${vi.lastOf()}`);
	out.push(`int32[] ${ri.onRef()} ${ri.onVec()} ${ri.lastOf()}`);
	out.push(`string[] ${rs.onRef()} ${rs.onVec()} ${rs.lastOf()}`);
	out.push(`joined ${vf.join(",")} ${vi.join(",")}`);
	console.log(out.join("|"));
}
main();
