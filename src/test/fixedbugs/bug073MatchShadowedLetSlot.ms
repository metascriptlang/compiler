// bug073: `const x = match(...)` in a sibling block of a same-named plain let
// borrowed the earlier variable's hoisted C slot — the lowered decl and its
// arm assignments lost the checker symbol, so the first sink destroyed an
// uninitialized slot (sgFormatHover SIGABRT, 2026-07-31).

function pick(sel: int32, tag: string): string {
	if (sel === 0) {
		let kw = "";
		kw = "var-" + tag;
		if (kw.length === 0) { return "unreachable"; }
	}
	if (sel === 1) {
		const kw = match (sel) {
			1 => "uno",
			_ => "y",
		};
		return "m-" + kw;
	}
	return "p-" + sel.toString();
}

function both(tag: string): string {
	let total = "";
	if (tag.length > 0) {
		let kw = "";
		kw = "head-" + tag;
		total = total + kw;
	}
	if (tag.length > 1) {
		const kw = match (tag) {
			"ab" => "mid-" + tag,
			_ => "other",
		};
		total = total + "|" + kw;
	}
	return total;
}

test "match-expr var beside same-named let keeps its own slot" {
	assert pick(1, "t") === "m-uno";
	assert pick(0, "z") === "p-0";
}

test "both blocks in one call: no double destroy" {
	assert both("ab") === "head-ab|mid-ab";
	assert both("x") === "head-x";
}
