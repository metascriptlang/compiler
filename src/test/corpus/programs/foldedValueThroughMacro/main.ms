// A @comptime value handed back by a macro keeps the type of the call it folded from: a struct
// field read through it, an int64 local that later takes a value past int32, and a float32 local
// passed on as float32, as the same program without the macro does.
//
// @stdout: 4 5000000000 0.75 6000000000 200
// @exit: 0

import { same, lengthOf, half } from "./lib";

struct Key { bytes: uint8[4]; }

@comptime function keyOf(n: int32): Key { return { bytes: [n as uint8, 2, 3, 4] }; }
@comptime function big(): int64 { return 5; }
@comptime function small(): float32 { return 1.5; }

function later<T>(x: T): int64 {
	let m = same(same(big()));
	m = 6000000000;
	return m;
}

let wide = same(big());
wide = 5000000000;
const f = same(small());
const u: uint8 = same(200);
console.log(`${lengthOf(keyOf(1))} ${wide} ${half(f)} ${later(1)} ${u}`);
