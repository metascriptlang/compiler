// @stdout: stmt=200,100,100,200,13,-1 value=short,long,long,short,r3,none ret=6,6,6,13,-1 loop=x:2,a1:11,q:-1 skipped=2
// note: a string match with more than eight arms runs the body of an arm with several alternatives once for whichever alternative matched, in statement, value and return position, with temporaries, a local array and break/continue inside that body.

function grow(s: string): string {
	return s + "!";
}

function stmtPick(s: string, a: boolean): int32 {
	let r: int32 = 0;
	match (s) {
		"a0" => { r = 10; },
		"a1" => { r = 11; },
		"a2" => { r = 12; },
		"a3" => { r = 13; },
		"a4" => { r = 14; },
		"a5" => { r = 15; },
		"a6" => { r = 16; },
		"a7" => { r = 17; },
		"x" | "yy" | "zz" => {
			if (a && grow(s).length > 2) {
				r = 100;
			} else {
				r = 200;
			}
		},
		_ => { r = -1; },
	}
	return r;
}

function valuePick(s: string, a: boolean): string {
	const t = match (s) {
		"a0" => "r0",
		"a1" => "r1",
		"a2" => "r2",
		"a3" => "r3",
		"a4" => "r4",
		"a5" => "r5",
		"a6" => "r6",
		"a7" => "r7",
		"x" | "yy" | "zz" => a && grow(s).length > 2 ? "long" : "short",
		_ => "none",
	};
	return t;
}

function retPick(s: string): int32 {
	return match (s) {
		"a0" => 10,
		"a1" => 11,
		"a2" => 12,
		"a3" => 13,
		"a4" => 14,
		"a5" => 15,
		"a6" => 16,
		"a7" => 17,
		"x" | "yy" | "zz" => {
			const xs: int32[] = [1, 2, 3];
			let n: int32 = 0;
			for (const v of xs) {
				n += v;
			}
			return n;
		},
		_ => -1,
	};
}

function loopPick(words: string[]): string {
	let out = "";
	let skipped: int32 = 0;
	for (const w of words) {
		let n: int32 = 0;
		match (w) {
			"a0" => { n = 10; },
			"a1" => { n = 11; },
			"a2" => { n = 12; },
			"a3" => { n = 13; },
			"a4" => { n = 14; },
			"a5" => { n = 15; },
			"a6" => { n = 16; },
			"a7" => { n = 17; },
			"x" | "yy" | "zz" | "stop" => {
				if (w == "stop") {
					break;
				}
				const tag = grow(w);
				if (tag.length > 2) {
					skipped += 1;
					continue;
				}
				n = 2;
			},
			_ => { n = -1; },
		}
		out = out + (out.length > 0 ? "," : "") + w + ":" + n.toString();
	}
	return out + " skipped=" + skipped.toString();
}

const stmt = [stmtPick("x", true), stmtPick("yy", true), stmtPick("zz", true), stmtPick("zz", false), stmtPick("a3", true), stmtPick("q", true)];
const value = [valuePick("x", true), valuePick("yy", true), valuePick("zz", true), valuePick("zz", false), valuePick("a3", true), valuePick("q", true)];
const ret = [retPick("x"), retPick("yy"), retPick("zz"), retPick("a3"), retPick("q")];
console.log(`stmt=${stmt.join(",")} value=${value.join(",")} ret=${ret.join(",")} loop=${loopPick(["x", "yy", "a1", "q", "zz", "stop", "x"])}`);
