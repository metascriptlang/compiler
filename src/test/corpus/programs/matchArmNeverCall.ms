// @stdout: 1 2 3 4 caught
function fail(message: string): never {
	throw new Error(message);
}
function byName(name: string): int32 {
	return match (name) {
		"a" => 1,
		_ => fail("no code for " + name),
	};
}
function byNumber(n: int32): int32 {
	return match (n) {
		2 => 2,
		_ => fail("no number"),
	};
}
function bound(name: string): int32 {
	const v: int32 = match (name) {
		"c" => 3,
		_ => 4,
	};
	return v;
}
let caught = "no";
try {
	byName("b");
} catch (e) {
	caught = "caught";
}
console.log(`${byName("a")} ${byNumber(2)} ${bound("c")} ${bound("d")} ${caught}`);
