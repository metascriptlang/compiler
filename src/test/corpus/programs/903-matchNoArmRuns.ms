// @stdout: sw=none,A,B|mt=none,A|fl=none,two|cf=0,1|du=1,2|en=r,g
type Mode = "a" | "b";
enum Color { Red, Green }
function sw(s: string): string {
	let r = "none";
	switch (s) {
		case "a":
			r = "A";
			break;
		case "b":
			r = "B";
			break;
	}
	return r;
}
function mt(s: string): string {
	let r = "none";
	match (s) {
		"a" => { r = "A"; },
	}
	return r;
}
function fl(n: float64): string {
	let r = "none";
	switch (n) {
		case 1.5:
			r = "one";
			break;
		case 2.5:
			r = "two";
			break;
	}
	return r;
}
function cf(cmd: string): int32 {
	let hits: int32 = 0;
	match (cmd) {
		"list" => { hits = hits + 1; },
		"show" => { hits = hits + 1; },
	}
	return hits;
}
function du(m: Mode): int32 {
	return match (m) {
		"a" => 1,
		"b" => 2,
	};
}
function en(c: Color): string {
	const s = match (c) {
		Color.Red => "r",
		Color.Green => "g",
	};
	return s;
}
function run(): void {
	const a = "sw=" + sw("z") + "," + sw("a") + "," + sw("b");
	const b = "mt=" + mt("z") + "," + mt("a");
	const c = "fl=" + fl(9.0) + "," + fl(2.5);
	const d = "cf=" + cf("delete-all").toString() + "," + cf("show").toString();
	const e = "du=" + du("a").toString() + "," + du("b").toString();
	const f = "en=" + en(Color.Red) + "," + en(Color.Green);
	console.log(a + "|" + b + "|" + c + "|" + d + "|" + e + "|" + f);
}
run();
