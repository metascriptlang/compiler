// @stdout: 1 1.5;2.5 1 3 9
// note: the array readers declare a Vec<T> receiver, so a const Vec, a shared T[] and a Readonly<T[]> call them alike and a class element they return stays writable; a receiver declared T[] writes and needs a writable source. Same output on every lane.
class C { n: int32 = 1; }

function firstOf<T>(this arr: Vec<T>): T {
	return arr[0];
}

function total(this arr: Vec<int32>): int32 {
	let s: int32 = 0;
	for (const x of arr) s += x;
	return s;
}

function main(): void {
	const v: Vec<int32> = [4, 5, 6];
	const shared: int32[] = [7, 8];
	const ro: Readonly<int32[]> = shared;
	const words: Vec<string> = ["a", "b", "c"];
	const nums: Vec<number> = [1.5, 2.5];
	const cs: Vec<C> = [new C(), new C()];
	cs.at(1).n = 9;
	cs.firstOf().n = 3;
	console.log(`${v.indexOf(5)} ${v.includes(6)} ${v.join(",")} ${v.slice(1).length} ${v.at(2)} ${v.concat([1]).length}`);
	console.log(`${v.map((x: int32, i: number): int32 => x * 2).join(",")} ${v.firstOf()} ${v.total()}`);
	console.log(`${shared.firstOf()} ${shared.total()} ${ro.firstOf()} ${ro.indexOf(8)} ${ro.join("+")}`);
	console.log(`${words.indexOf("c")} ${words.includes("z")} ${words.join("-")} ${words.slice(0, 2).join("")} ${words.at(1)}`);
	console.log(`${nums.indexOf(2.5)} ${nums.join(";")} ${nums.slice(1).length} ${cs[0].n} ${cs[1].n}`);
}
main();
