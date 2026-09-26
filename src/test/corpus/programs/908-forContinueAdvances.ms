// @stdout: int=023 str=ac match=023 deep=02x brk=0s34 nest=00,02,;20,22,;
function intSwitch(): string {
	let out = "";
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 4; i++) {
		guard += 1;
		if (guard > 20) return out + "HANG";
		switch (i) {
			case 1:
				continue;
			default:
				out = out + i.toString();
		}
	}
	return out;
}

function strSwitch(): string {
	const names = ["a", "b", "c"];
	let out = "";
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 3; i += 1) {
		guard += 1;
		if (guard > 20) return out + "HANG";
		switch (names[i]) {
			case "b":
				continue;
			default:
				out = out + names[i];
		}
	}
	return out;
}

function matchArm(): string {
	let out = "";
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 4; i++) {
		guard += 1;
		if (guard > 20) return out + "HANG";
		match (i) {
			1 => { continue; }
			_ => { out = out + i.toString(); }
		}
	}
	return out;
}

function deeper(): string {
	let out = "";
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 4; i++) {
		guard += 1;
		if (guard > 20) return out + "HANG";
		switch (i % 2) {
			case 1:
				if (i < 3) {
					match (i) {
						1 => { if (guard > 0) { continue; } }
						_ => {}
					}
				}
				out = out + "x";
				break;
			default:
				out = out + i.toString();
		}
	}
	return out;
}

function breaks(): string {
	let out = "";
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 6; i++) {
		guard += 1;
		if (guard > 20) return out + "HANG";
		if (i == 1) continue;
		switch (i) {
			case 2:
				out = out + "s";
				break;
			default:
				out = out + i.toString();
		}
		match (i) {
			4 => { break; }
			_ => {}
		}
	}
	return out;
}

function nested(): string {
	let out = "";
	let guard: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		for (let j: int32 = 0; j < 3; j++) {
			guard += 1;
			if (guard > 40) return out + "HANG";
			switch (j) {
				case 1:
					continue;
				default:
					guard += 0;
			}
			if (i == 1) continue;
			out = out + i.toString() + j.toString() + ",";
		}
		switch (i) {
			case 0:
				continue;
			default:
				out = out + ";";
		}
	}
	return out;
}

console.log(`int=${intSwitch()} str=${strSwitch()} match=${matchArm()} deep=${deeper()} brk=${breaks()} nest=${nested()}`);
