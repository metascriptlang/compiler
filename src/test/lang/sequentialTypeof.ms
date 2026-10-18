function sequentialText(x: int32 | string | boolean): string {
	let text = "";
	if (typeof x === "number") text = "n:" + (x + 1).toString();
	if (typeof x === "string") text = "s:" + x;
	if (typeof x === "boolean") text = "b:" + (x ? "yes" : "no");
	return text;
}

function reorderedText(x: string | boolean | int32): string {
	let text = "";
	if (typeof x === "boolean") text = x ? "yes" : "no";
	if (typeof x === "number") text = (x + 2).toString();
	if (typeof x === "string") text = x + "!";
	return text;
}

test "sequential typeof: later guards use original storage tags after a branch rejoins" {
	assert sequentialText(7) == "n:8";
	assert sequentialText("hi") == "s:hi";
	assert sequentialText(true) == "b:yes";
	assert sequentialText(false) == "b:no";
}

test "sequential typeof: declaration member order does not alter the active payload" {
	assert reorderedText(7) == "9";
	assert reorderedText("hi") == "hi!";
	assert reorderedText(true) == "yes";
	assert reorderedText(false) == "no";
}
