// @stdout: ab c 2 a-1
// note: a match whose arms are literals takes the slot it sits in as each arm's contextual type, as a ternary does, so a string-literal and a number-literal union are kept and no arm widens to string or int32.

type Kind = "a" | "b" | "c";
type Level = 1 | 2;
enum E { X, Y, Z }

function viaTernary(e: E): Kind {
	return e == E.X ? "a" : "b";
}
function viaMatch(e: E): Kind {
	return match (e) {
		E.X => "a",
		E.Y => "b",
		E.Z => "c",
	};
}
function viaConst(e: E): string {
	const k: Kind = match (e) { E.X => "a", E.Y => "b", E.Z => "c" };
	return k;
}
function level(e: E): Level {
	return match (e) {
		E.X => 1,
		E.Y => 2,
		E.Z => 2,
	};
}
function nested(e: E, flag: boolean): Kind {
	return flag ? match (e) { E.X => "a", E.Y => "b", E.Z => "c" } : "a";
}

console.log(viaTernary(E.X) + viaMatch(E.Y), viaConst(E.Z), level(E.Y), nested(E.X, true) + "-" + level(E.X).toString());
