for (let i = 0; i < 2; i++) {
	const b: string[] = ["a" + String(i)];
	let hold: string[] = [];
	try {
		hold = b;
		throw new Error("x");
	} catch (e) {
		console.log("array catch " + String(b.length));
	}
	console.log("array held " + hold[0]);
}

let round = 0;
while (round < 2) {
	{
		const s = "s" + String(round);
		let kept = "";
		try {
			kept = s;
			if (round >= 0) throw new Error("y");
		} catch (e) {
			console.log("string catch " + s);
		}
		console.log("string kept " + kept);
	}
	round += 1;
}
