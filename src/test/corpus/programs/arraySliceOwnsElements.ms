// @stdout: 2 b2x c3x changed
// @stdout: 2 c3x 0 5 4 4
// @stdout: 2 pqz r
// @stdout: 30 n10 n39
struct Tagged { name: string; n: int32; }

function main(): void {
	const names: string[] = ["a" + "1", "b" + "2", "c" + "3", "d" + "4"];
	const tags: Tagged[] = [];
	for (let i = 0; i < 4; i++) tags.push({ name: names[i] + "x", n: i });
	const mid = tags.slice(1, 3);
	tags[1].name = "changed";
	console.log(`${mid.length} ${mid[0].name} ${mid[1].name} ${tags[1].name}`);
	const tail = tags.slice(-2);
	const none = tags.slice(3, 1);
	const all = tags.slice();
	all.push({ name: "e", n: 9 });
	console.log(`${tail.length} ${tail[0].name} ${none.length} ${all.length} ${tags.length} ${tags.slice(-100, 100).length}`);
	const nested: string[][] = [["p", "q"], ["r"], []];
	const part = nested.slice(0, 2);
	part[0].push("z");
	console.log(`${part.length} ${nested[0].join("")} ${part[1].join("")}`);
	const objs: Tagged[][] = [];
	for (let i = 0; i < 50; i++) objs.push([{ name: `n${i}`, n: i }]);
	const half = objs.slice(10, 40);
	console.log(`${half.length} ${half[0][0].name} ${half[29][0].name}`);
}
main();
