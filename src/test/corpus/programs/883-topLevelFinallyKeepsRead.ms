for (let i = 0; i < 2; i++) {
	const b: string[] = ["a" + String(i)];
	let hold: string[] = [];
	try {
		hold = b;
	} finally {
		console.log("array finally " + String(b.length));
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
		} finally {
			console.log("string finally " + s);
		}
		console.log("string kept " + kept);
	}
	round += 1;
}
