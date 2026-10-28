// @stdout: null 4 null s
// note: `as` out of a `scalar | string | null` into a target that admits null keeps an absent value as null, and a held member as itself.

function pick(k: int32): int32 | string | null {
	if (k == 0) return null;
	if (k == 1) return 4;
	return "s";
}

const none = pick(0) as int32 | null;
const held = pick(1) as int32 | null;
const noneS = pick(0) as string | null;
const heldS = pick(2) as string | null;
console.log(`${none == null ? "null" : none} ${held == null ? "null" : held} ${noneS == null ? "null" : noneS} ${heldS == null ? "null" : heldS}`);
