let calls = 0;
function touch(): void { calls += 1; }
function skippedLs(): void { return touch(); }
function skippedPs(): void { return touch(); }

const rawLs = "a b";
const rawPs = "a b";
const rawTemplate = `a b`;
const continuedLs = "a\ b";
const continuedPs = `a\ b`;

test "Unicode line separators prevent a return from calling the following expression" {
	calls = 0;
	skippedLs();
	skippedPs();
	assert calls == 0;
}

test "Unicode literal data is preserved while escaped line continuations are empty" {
	assert rawLs.length == 3 && rawLs.charCodeAt(1) == 0x2028;
	assert rawPs.length == 3 && rawPs.charCodeAt(1) == 0x2029;
	assert rawTemplate == rawLs;
	assert continuedLs == "ab" && continuedPs == "ab";
}
