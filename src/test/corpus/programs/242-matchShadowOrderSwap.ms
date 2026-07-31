// Parity program — benign orderings that must STAY green: match-block before
// the plain let, and two sibling match-blocks sharing a name.

function pick(sel: int32, tag: string): string {
	if (sel === 1) {
		const kw = match (sel) {
			1 => "uno-" + tag,
			_ => "y",
		};
		console.log("m=" + kw);
	}
	if (sel === 0) {
		let kw = "";
		kw = "plain-" + tag;
		console.log("p=" + kw);
	}
	return "ok";
}

function twin(sel: int32): string {
	if (sel === 1) {
		const kw = match (sel) { 1 => "a", _ => "b", };
		console.log("t1=" + kw);
	}
	if (sel >= 1) {
		const kw = match (sel) { 1 => "c", _ => "d", };
		console.log("t2=" + kw);
	}
	return "ok";
}

function main(): void {
	console.log(pick(1, "a"));
	console.log(pick(0, "b"));
	console.log(twin(1));
}
main();
