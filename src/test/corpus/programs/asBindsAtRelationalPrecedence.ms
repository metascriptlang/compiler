// @stdout: f32 0.30000001192092896 0.30000001192092896 | i64 12 7 calls=2 | left 1.25
let calls = 0;
function f(): int32 { calls++; return 3; }
function g(): int32 { calls++; return 4; }
function wide(v: int64): int64 { return v; }

const x: float64 = 0.1;
const y: float64 = 0.2;
const count: int32 = 3;
const size: int32 = 4;
const half: float64 = 2.5;
console.log(`f32 ${x + y as float32} ${(x + y) as float32} | i64 ${wide(count * size as int64)} ${wide(f() + g() as int64)} calls=${calls} | left ${half as float32 / 2}`);
