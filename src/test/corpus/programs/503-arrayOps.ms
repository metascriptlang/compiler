// Parity program — std array surface: push/pop/shift/slice/concat/indexOf/
// includes/join/reverse/sort/fill/splice on number[] and string[], plus a
// churn loop (RC-stress: string elements relayed through slices then dropped).

function dump(label: string, arr: number[]): void {
	console.log(label + "=[" + arr.join(",") + "] len=" + arr.length.toString());
}

function dumpS(label: string, arr: string[]): void {
	console.log(label + "=[" + arr.join(",") + "] len=" + arr.length.toString());
}

function main(): void {
	const a: number[] = [3, 1, 2];
	a.push(10);
	dump("push", a);
	const p = a.pop();
	console.log("pop=" + p.toString());
	const sh = a.shift();
	console.log("shift=" + sh.toString());
	dump("after", a);

	const b = a.concat([7, 8, 9]);
	dump("concat", b);
	dump("slice", b.slice(1, 4));
	console.log("indexOf7=" + b.indexOf(7).toString());
	console.log("includes8=" + (b.includes(8) ? "y" : "n"));
	console.log("includes99=" + (b.includes(99) ? "y" : "n"));

	const c: number[] = [5, 3, 9, 1, 20];
	c.sort();
	dump("sortNum", c);
	c.reverse();
	dump("revNum", c);
	c.fill(0);
	dump("fill", c);

	const s: string[] = ["pear", "apple", "fig"];
	s.push("date");
	s.sort();
	dumpS("sortStr", s);
	s.reverse();
	dumpS("revStr", s);
	console.log("joinStr=" + s.join("|"));
	s.splice(1, 2);
	dumpS("splice", s);

	let bytes = 0;
	for (let round = 0; round < 50; round += 1) {
		const churn: string[] = [];
		for (let i = 0; i < 40; i += 1) {
			churn.push("item" + i.toString() + "r" + round.toString());
		}
		const cut = churn.slice(10, 30);
		bytes = bytes + cut.length + churn.length;
	}
	console.log("churn=" + bytes.toString());
}

main();
