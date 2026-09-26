// @stdout: M2 d E x|A1 z1 d|7 d
enum K { A, B, C }
function matchInIntCase(k: int32): string {
	let out = "";
	switch (k) {
		case 2:
			match (k) {
				2 => { out = out + "M"; }
				_ => { out = out + "m"; }
			}
			out = out + "2";
			break;
		default:
			out = out + "d";
	}
	return out;
}
function matchInEnumCase(e: K): string {
	let out = "";
	switch (e) {
		case K.B:
			match (e) {
				K.B => { out = out + "E"; }
				_ => {}
			}
			break;
		default:
			out = out + "x";
	}
	return out;
}
function stringSwitchInCase(k: int32, s: string): string {
	let out = "";
	switch (k) {
		case 1:
			switch (s) {
				case "a": out = out + "A"; break;
				default: out = out + "z";
			}
			out = out + "1";
			break;
		default:
			out = out + "d";
	}
	return out;
}
function destructureInCase(k: int32, xs: int32[]): string {
	switch (k) {
		case 1:
			const [a, b] = xs;
			return (a + b).toString();
		default:
			return "d";
	}
}
console.log(matchInIntCase(2) + " " + matchInIntCase(1) + " " + matchInEnumCase(K.B) + " " + matchInEnumCase(K.A)
	+ "|" + stringSwitchInCase(1, "a") + " " + stringSwitchInCase(1, "q") + " " + stringSwitchInCase(2, "a")
	+ "|" + destructureInCase(1, [3, 4]) + " " + destructureInCase(2, [3, 4]));
