export struct Op {
	run: (x: int32) => int32;
	base: int32;
}

@wasm
export function adder(n: int32): (x: int32) => int32 {
	return (x: int32): int32 => x + n;
}

@wasm
export function apply(o: Op): int32 {
	return o.run(o.base) + o.base;
}
