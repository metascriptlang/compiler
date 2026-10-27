// @stdout: float32 5 2
// @stdout: trunc 3
// @stdout: big 6
// @stdout: number 3
// @stdout: global 7
// note: a name the author binds never captures a JS global the compiler emits. An exported `class Float32Array`, a parameter `Int8Array`, a local `Math` with its own `trunc`, a local `BigInt`, a local `Number` and a local `globalThis` (beside a class-typed object literal) each sit in a function that emits float32 arrays, an int64 conversion or a sized array; JS spelled these globals bare and read the author's binding.
export class Float32Array {
	tag: string = "float32";
}

class FakeMath {
	trunc(x: number): number { return 999; }
}

function typedArray(Int8Array: int32): int32 {
	const a: int8[2] = [3, 4];
	return Int8Array + a[1] - 1;
}

function truncated(x: float64): int64 {
	const Math = new FakeMath();
	return x as int64;
}

function bigint(x: float64): int64 {
	const BigInt = (v: number): number => v * 1000;
	return (x as int64) * 2;
}

function number(x: int64): int32 {
	const Number = (v: number): number => v * 1000;
	return x as int32;
}

class Box {
	v: int32 = 1;
}

function shadowedGlobal(): int64 {
	const globalThis = 7;
	const a: float32[2] = [1.5, 2.5];
	const box: Box = { v: 4 };
	return (a[0] as int64) + (globalThis as int64) + (box.v as int64) - 5;
}

const f32: float32[2] = [1.5, 2.5];
console.log(`float32 ${typedArray(2)} ${f32[1] as int32}`);
console.log(`trunc ${truncated(3.7)}`);
console.log(`big ${bigint(3.2)}`);
console.log(`number ${number(3)}`);
console.log(`global ${shadowedGlobal()}`);
console.log(new Float32Array().tag);
