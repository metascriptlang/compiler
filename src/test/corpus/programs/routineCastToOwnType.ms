// @stdout: 7 7 12 7 -1 7
function seven(): int32 { return 7; }
function add(a: int32, b: int32): int32 { return a + b; }
class Box { static seven(): int32 { return 7; } }

function orMinus(f: (() => int32) | null): int32 {
	if (f == null) return -1;
	return f();
}

const plain = seven as (() => int32);
const method = Box.seven as (() => int32);
const sum = add as ((a: int32, b: int32) => int32);
const maybe = seven as ((() => int32) | null);
const none = null as ((() => int32) | null);
const parts: int32[] = [plain(), method(), sum(5, 7), orMinus(maybe), orMinus(none), orMinus(Box.seven as (() => int32))];
console.log(parts.join(" "));
