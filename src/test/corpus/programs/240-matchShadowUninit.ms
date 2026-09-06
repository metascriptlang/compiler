// Parity program — `const kw = match(...)` in a sibling block after a plain
// same-named `let kw`: the lowered decl must keep its own binding instead of
// borrowing the earlier variable's hoisted C slot (uninit-destroy shape).

function pick(sel: int32, tag: string): string {
	if (sel == 0) {
		let kw = "";
		kw = "var-" + tag;
		console.log("first=" + kw);
	}
	if (sel == 1) {
		const kw = match (sel) {
			1 => "uno",
			_ => "y",
		};
		console.log("second=" + kw);
	}
	return "done-" + sel.toString();
}

function main(): void {
	console.log(pick(1, "t"));
	console.log(pick(0, "z"));
}
main();
