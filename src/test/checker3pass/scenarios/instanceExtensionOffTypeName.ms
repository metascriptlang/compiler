import { checkOnly } from "../helpers";

const SRC_ALIAS = `
type Bag = int32[];
function size(this b: Bag): number { return b.length; }
const n = Bag.size();
`;

const SRC_CLASS = `
class Box { w: int32 = 1; }
function weight(this b: Box): int32 { return b.w; }
const n = Box.weight();
`;

const SRC_BOTH = `
type Bag = int32[];
function size(this typeof Bag, s: string): number { return s.length; }
function size(this b: Bag): number { return b.length; }
const b: Bag = [1 as int32];
const n = b.size() + Bag.size("abc");
`;

test "an instance extension is not a member of a type alias name" {
	const text = checkOnly(SRC_ALIAS).errors.join("\n");
	assert text.contains("Property 'size' does not exist"), "Bag.size() must not bind the instance extension: " + text;
}

test "an instance extension is not a member of a class name" {
	const text = checkOnly(SRC_CLASS).errors.join("\n");
	assert text.contains("Property 'weight' does not exist"), "Box.weight() must not bind the instance extension: " + text;
}

test "a static and an instance extension of one name each keep their receiver" {
	const result = checkOnly(SRC_BOTH);
	assert result.errors.length == 0, "both forms must check: " + result.errors.join("\n");
}
