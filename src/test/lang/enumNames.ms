enum Kind { A, B, C }
enum Holes { P = 1, Q = 5, R = 9 }
struct Tagged { kind: Kind; }

function conv(n: int32): Kind { return n as Kind; }
function tagged(n: int32): Tagged { return { kind: n as Kind }; }
function shown(k: Kind): string { return `${k}`; }
function hole(n: int32): Holes { return n as Holes; }

test "enumNames: an enum from a call prints its member name in a template, String and toString" {
	const k = conv(2);
	assert `${k}` == "C";
	assert String(conv(1)) == "B";
	assert conv(0).toString() == "A";
}

test "enumNames: an enum from a parameter, a field or an annotated local prints its member name" {
	assert shown(conv(1)) == "B";
	assert `${tagged(2).kind}` == "C";
	const k: Kind = conv(0);
	assert `${k}` == "A";
}

test "enumNames: an enum with explicit values prints the member that holds the value" {
	assert `${hole(5)}` == "Q";
	assert String(hole(9)) == "R";
	assert hole(1).toString() == "P";
}
