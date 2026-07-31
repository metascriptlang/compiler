// Parity program — plain `let kw` block runs, then a sibling
// `const kw = match(...)` block runs in the same call: each binding owns its
// value exactly once (double-destroy shape when the slots collide).

function run(tag: string): string {
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

function main(): void {
	console.log(run("ab"));
	console.log(run("x"));
}
main();
