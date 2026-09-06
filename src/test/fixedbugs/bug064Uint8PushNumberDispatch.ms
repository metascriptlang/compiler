// bug064 — uint8[].push silently wrote doubles through msNumberArrayPush
//
// Symptom:    `bytes.push(104)` on a uint8[] compiled to
//             `msNumberArrayPush(bytes, 104.0)` — an 8-byte double stored
//             into a 1-byte payload. Reads then returned the LOW BYTE of the
//             double bit pattern: 104.0 → 0x405A000000000000 → bytes[0] === 0.
//             len was right, data was garbage. Silent wrong answer; std's own
//             serialize/json accessors pushed uint8 through this path on C.
//
// Root cause: std declared push only for number[]/string[]/T[]; a uint8[]
//             receiver widened onto the number[] extern. Adding the exact
//             uint8[] overload then turned every such call into "Ambiguous
//             call" because resolveExtensionOverloadCall strips the receiver
//             before scoring — `this uint8[]` and `this number[]` tied.
//
// Fix:        std/core/array/index.cms declares
//             `push(this arr: uint8[], value: uint8) from "&msUint8ArrayPush"`
//             (runtime fn existed, was never referenced), and the checker
//             pre-filters overload candidates to exact-receiver matches when
//             any exist — widening never ties against an exact receiver.
//
// The 15 other number[] methods (at/pop/fill/indexOf/…) still have NO uint8[]
// overloads and still mis-dispatch — tracked in Neon BUGS.md §2.

test "bug064: pushed bytes read back as themselves" {
	const bytes: uint8[] = [];
	bytes.push(104);
	bytes.push(105);
	assert bytes.length == 2;
	assert bytes[0] == 104;
	assert bytes[1] == 105;
}

test "bug064: push from a variable, not just literals" {
	const bytes: uint8[] = [];
	const v: uint8 = 200;
	bytes.push(v);
	assert bytes[0] == 200;
}

test "bug064: number[] push is untouched by the uint8 overload" {
	const nums: number[] = [];
	nums.push(1.5);
	nums.push(2.5);
	assert nums[0] == 1.5;
	assert nums[1] == 2.5;
}

test "bug064: growth across the initial capacity keeps bytes intact" {
	const bytes: uint8[] = [];
	let i: int32 = 0;
	while (i < 100) {
		bytes.push((i % 256) as uint8);
		i = i + 1;
	}
	assert bytes.length == 100;
	assert bytes[0] == 0;
	assert bytes[42] == 42;
	assert bytes[99] == 99;
}
