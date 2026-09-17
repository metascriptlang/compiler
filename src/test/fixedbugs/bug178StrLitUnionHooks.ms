export type Dir = "column" | "column-reverse" | "row" | "row-reverse";

export function dirToC(v: Dir): int32 {
	return match (v) {
		"column" => 0,
		"column-reverse" => 1,
		"row" => 2,
		"row-reverse" => 3,
	};
}

interface Holder {
	dir: Dir;
	label: string;
}

test "a named string-literal union matches on its msString carrier" {
	const d: Dir = "row";
	assert dirToC(d) === 2, "row";
}

test "a struct field typed by a named string-literal union copies and drops as a string" {
	const a: Holder = { dir: "row-reverse", label: "x" };
	const b = a;
	assert dirToC(b.dir) === 3 && b.label === "x", "copy";
}
