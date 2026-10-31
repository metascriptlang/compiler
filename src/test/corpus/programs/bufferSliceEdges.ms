// @stdout: 5:1,2,3,4,5,
// @stdout: 3:3,4,5,
// @stdout: 2:4,5,
// @stdout: 3:2,3,4,
// @stdout: 2:1,2,
// @stdout: 4:2,3,4,5,
// @stdout: 0:
// @stdout: 0:
// @stdout: 0:
// @stdout: 0:
// @stdout: 0:
// @stdout: 0:
// @stdout: 0:
// @stdout: 98000 247 105
// @stdout: 247 9
// @stdout: 1 42 10 15 7
// @stdout: 9 3:7,8,9,

import { Buffer } from "std/core/buffer";

function show(b: uint8[]): string {
	let out = `${b.length}:`;
	for (let i = 0; i < b.length; i++) out += `${b[i]},`;
	return out;
}

const b = Buffer.fromArray([1, 2, 3, 4, 5]);
console.log(show(b.slice()));
console.log(show(b.slice(2)));
console.log(show(b.slice(-2)));
console.log(show(b.slice(1, -1)));
console.log(show(b.slice(-100, 2)));
console.log(show(b.slice(1, 100)));
console.log(show(b.slice(3, 2)));
console.log(show(b.slice(5)));
console.log(show(b.slice(100)));
console.log(show(b.slice(-1, -3)));
console.log(show(Buffer.alloc(0).slice()));
console.log(show(Buffer.allocUnsafe(0)));
console.log(show(Buffer.concat(Buffer.alloc(0), Buffer.alloc(0))));

const big = Buffer.alloc(100000);
for (let i = 0; i < big.length; i++) big[i] = (i % 251) as uint8;
const part = big.slice(1000, 99000);
console.log(`${part.length} ${part[0]} ${part[part.length - 1]}`);
part[0] = 9;
console.log(`${big[1000]} ${part[0]}`);

const c = Buffer.copy(b);
c[0] = 42;
console.log(`${b[0]} ${c[0]} ${Buffer.concat(b, c).length} ${Buffer.concatList([b, c, b]).length} ${Buffer.allocUnsafe(7).length}`);
const z = Buffer.alloc(9);
let zeros = 0;
for (let i = 0; i < z.length; i++) if (z[i] == 0) zeros++;
console.log(`${zeros} ${show(Buffer.fromArray([7, 8, 9]))}`);
