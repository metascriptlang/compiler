import {
	batchArguments,
	WINDOWS_COMMAND_LINE_UNITS,
} from "./argumentBatches";

let cases: int32 = 0;

function batchesOf(
	executable: string,
	prefix: string[],
	members: string[],
	limit: int32,
): string[][] {
	const result = batchArguments(executable, prefix, members, limit);
	if (!result.ok) { throw new Error(result.error); }
	return result.value;
}

function expectBatches(
	executable: string,
	prefix: string[],
	members: string[],
	limit: int32,
	expected: string[][],
): void {
	const actual = batchesOf(executable, prefix, members, limit);
	if (actual.length != expected.length) {
		throw new Error(
			"batch count " + String(actual.length) + " != " +
				String(expected.length),
		);
	}
	for (let i: int32 = 0; i < expected.length; i += 1) {
		if (actual[i].length != expected[i].length) {
			throw new Error("batch " + String(i) + " size differs");
		}
		for (let j: int32 = 0; j < expected[i].length; j += 1) {
			if (actual[i][j] != expected[i][j]) {
				throw new Error(
					"batch " + String(i) + " member " + String(j) + " differs",
				);
			}
		}
	}
	cases += 1;
}

function expectRefusal(
	executable: string,
	prefix: string[],
	members: string[],
	limit: int32,
	message: string,
): void {
	const result = batchArguments(executable, prefix, members, limit);
	if (result.ok) { throw new Error("accepted: " + message); }
	if (result.error.indexOf(message) < 0) { throw new Error(result.error); }
	cases += 1;
}

// `units` is the hand-counted size of the whole command line with its NUL:
// accepted exactly at the limit, refused one unit below it.
function expectFixedUnits(
	executable: string,
	prefix: string[],
	units: int32,
): void {
	expectBatches(executable, prefix, [], units, []);
	expectRefusal(executable, prefix, [], units - 1, "fixed command line");
}

// The same boundary for one member after executable `a` (1 unit) and its NUL.
function expectMemberUnits(member: string, units: int32): void {
	expectBatches("a", [], [member], units, [[member]]);
	expectRefusal("a", [], [member], units - 1, "does not fit");
}

// executable and prefix tokens
expectFixedUnits("a", [], 2);
expectFixedUnits("a", ["bb"], 5);
expectFixedUnits("a", [""], 5);
expectFixedUnits("a b", [], 6);
expectFixedUnits("a\tb", [], 6);
expectFixedUnits("a b/", [], 8);
expectFixedUnits("C:/tools/x.exe", [], 15);
expectFixedUnits("\u00E9", [], 2);
expectFixedUnits("\uE000", [], 2);
expectFixedUnits("🚀", [], 3);
expectFixedUnits("e".repeat(32764), ["a"], 32767);

// member tokens: plain, quoted, escaped, UTF-16 widths
expectMemberUnits("bb", 5);
expectMemberUnits("", 5);
expectMemberUnits("a b", 8);
expectMemberUnits("a\tb", 8);
expectMemberUnits("a\"b", 9);
expectMemberUnits("\"", 7);
expectMemberUnits("a\\b", 6);
expectMemberUnits("\\\\", 5);
expectMemberUnits("\\\\ ", 8);
expectMemberUnits("a b\\", 10);
expectMemberUnits("a\\\\\"", 12);
expectMemberUnits("C:\\dir\\", 10);
expectMemberUnits("C:\\my dir\\", 16);
expectMemberUnits("a/b", 6);
expectMemberUnits("a b/", 9);
expectMemberUnits("a\nb", 6);
expectMemberUnits("\u00E9", 4);
expectMemberUnits("\uE000", 4);
expectMemberUnits("🚀", 5);
expectMemberUnits("\u00E9 🚀", 9);

// batching: order, duplicates, exact fill, no reordering
expectBatches("a", ["a", "b"], [], WINDOWS_COMMAND_LINE_UNITS, []);
expectBatches(
	"a", [], ["bb", "bb", "c", "bb"], 8,
	[["bb", "bb"], ["c", "bb"]],
);
expectBatches(
	"a", ["rcs"], ["aa", "aa", "a"], 12,
	[["aa", "aa"], ["a"]],
);
expectBatches(
	"a", [], ["xxxx", "y", "z"], 8,
	[["xxxx"], ["y", "z"]],
);
expectBatches(
	"a", [], ["y", "xxxx", "z"], 8,
	[["y"], ["xxxx"], ["z"]],
);
expectBatches(
	"a", [], ["🚀", "🚀", "🚀"], 8,
	[["🚀", "🚀"], ["🚀"]],
);
expectBatches(
	"a", [], ["\u00E9", "\u00E9", "\u00E9", "\u00E9"], 8,
	[["\u00E9", "\u00E9", "\u00E9"], ["\u00E9"]],
);
expectBatches(
	"a", [], ["\uE000", "\uE000", "\uE000", "\uE000"], 8,
	[["\uE000", "\uE000", "\uE000"], ["\uE000"]],
);
const wide = "x".repeat(16000);
expectBatches(
	"a", [], [wide, wide, wide], WINDOWS_COMMAND_LINE_UNITS,
	[[wide, wide], [wide]],
);
expectBatches(
	"a", [], ["x".repeat(32764)], WINDOWS_COMMAND_LINE_UNITS,
	[["x".repeat(32764)]],
);

// many members: order kept, each batch within the limit and full
function expectPacked(): void {
	const members: string[] = [];
	for (let i: int32 = 0; i < 1000; i += 1) {
		members.push("m" + String(i));
	}
	const batches = batchesOf("a", ["rcs"], members, 100);
	if (batches.length < 2) { throw new Error("one batch for 1000 members"); }
	let next: int32 = 0;
	for (let b: int32 = 0; b < batches.length; b += 1) {
		if (batches[b].length == 0) { throw new Error("empty batch"); }
		let used: int32 = 6;
		for (const member of batches[b]) {
			if (member != members[next]) {
				throw new Error("order differs at " + String(next));
			}
			used += 1 + member.length;
			next += 1;
		}
		if (used > 100) { throw new Error("batch over limit"); }
		if (b + 1 < batches.length &&
			used + 1 + batches[b + 1][0].length <= 100) {
			throw new Error("batch " + String(b) + " is not full");
		}
	}
	if (next != members.length) { throw new Error("members lost or added"); }
	cases += 1;
}
expectPacked();

// the default limit is the CreateProcessW one
if (WINDOWS_COMMAND_LINE_UNITS != 32767) { throw new Error("limit differs"); }
cases += 1;
const defaulted = batchArguments("a", [], ["x".repeat(32765)]);
if (defaulted.ok) { throw new Error("default limit accepted 32768 units"); }
cases += 1;
const fitting = batchArguments("a", [], ["x".repeat(32764)]);
if (!fitting.ok || fitting.value.length != 1) {
	throw new Error("default limit refused 32767 units");
}
cases += 1;

// inputs are borrowed, not changed
const frozenExecutable = "a b";
const frozenPrefix = ["rcs", "x y"];
const frozenMembers = ["m1", "m 2", "m3"];
batchesOf(frozenExecutable, frozenPrefix, frozenMembers, 20);
if (frozenExecutable != "a b" || frozenPrefix.length != 2 ||
	frozenPrefix[0] != "rcs" || frozenPrefix[1] != "x y" ||
	frozenMembers.length != 3 || frozenMembers[0] != "m1" ||
	frozenMembers[1] != "m 2" || frozenMembers[2] != "m3") {
	throw new Error("inputs changed");
}
cases += 1;

// refusals: no partial success
for (const limit of [0, -1, 32768]) {
	expectRefusal("a", [], ["b"], limit, "limit must be between");
}
expectRefusal("", [], ["b"], 100, "executable is empty");
expectRefusal("a\0b", [], ["b"], 100, "executable contains NUL");
expectRefusal("a", ["x", "a\0b"], ["b"], 100, "prefix[1] contains NUL");
expectRefusal("a", [], ["b", "a\0b"], 100, "members[1] contains NUL");
expectRefusal("a", [], ["\uD800"], 100, "members[0] is not well-formed");
expectRefusal("a", ["\uDC00"], ["b"], 100, "prefix[0] is not well-formed");
expectRefusal(
	"a", ["x".repeat(20)], ["b"], 10, "fixed command line needs 23 units",
);
expectRefusal(
	"e".repeat(32767), [], [], WINDOWS_COMMAND_LINE_UNITS,
	"fixed command line needs 32768 units",
);
expectRefusal("a", [], ["x".repeat(20)], 10, "members[0] does not fit");
expectRefusal(
	"a", [], ["b", "x".repeat(50), "c"], 10,
	"members[1] does not fit: needs 53 units",
);
console.log("argumentBatches: " + String(cases) + " cases OK");
