// Parity program — the arms of a match used as a value take the literal union their context expects:
// in a return, an initialiser, a struct field, a block tail and a nullable slot.
//
// @stdout: left,neither,right
// @stdout: left,right
// @stdout: left,none
// @exit: 0

type Side = "left" | "right";
type Key = "a" | "b";
type Sides = "neither" | "left";
enum E { A, B }
struct Holder { side: Side; }

function side(k: Key): Side {
	return match (k) {
		"a" => "left",
		_ => "right",
	};
}
function viaEnum(e: E): Sides {
	const s: Sides = match (e) { E.A => "neither", E.B => "left" };
	return s;
}
function field(k: Key): Holder {
	return match (k) { "a" => ({ side: "left" }), _ => ({ side: "right" }) };
}
function tail(k: Key): Side {
	return match (k) { "a" => { const x = 1; "left" }, _ => "right" };
}
function maybe(k: Key): Side | null {
	return match (k) { "a" => "left", _ => null };
}

console.log(side("a") + "," + viaEnum(E.A) + "," + side("b"));
console.log(field("a").side + "," + field("b").side);
console.log(tail("a") + "," + (maybe("b") ?? "none"));
