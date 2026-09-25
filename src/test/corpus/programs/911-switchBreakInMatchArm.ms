// @stdout: for=b;;d; while=b;;d; bare=M;x
function inFor(): string {
	const names = ["a", "b", "c", "d"];
	let out = "";
	for (let i: int32 = 0; i < 4; i++) {
		if (i == 0) continue;
		switch (names[i]) {
			case "c":
				match (i) {
					2 => { break; }
					_ => {}
				}
				out = out + "after";
			default:
				out = out + names[i];
		}
		out = out + ";";
	}
	return out;
}

function inWhile(): string {
	const names = ["a", "b", "c", "d"];
	let out = "";
	let i: int32 = 0;
	while (i < 3) {
		i += 1;
		switch (names[i]) {
			case "c":
				match (i) {
					2 => { break; }
					_ => {}
				}
				out = out + "after";
			default:
				out = out + names[i];
		}
		out = out + ";";
	}
	return out;
}

function bare(k: string): string {
	let out = "";
	switch (k) {
		case "m":
			match (k.length) {
				1 => { out = out + "M"; break; }
				_ => {}
			}
			out = out + "after";
		default:
			out = out + "x";
	}
	return out;
}

console.log(`for=${inFor()} while=${inWhile()} bare=${bare("m")};${bare("z")}`);
