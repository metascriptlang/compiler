// @stdout: 2.9876 1 3.0
// @stdout: 1.005 2 1.00
// @stdout: 2.5 0 3
// @stdout: -2.5 0 -3
// @stdout: 0.125 2 0.13
// @stdout: -0.0001 2 -0.00
// @stdout: 123456789012345680000 2 123456789012345683968.00
// @stdout: 1e+21 2 1e+21
// @stdout: 0.1 20 0.10000000000000000555
// note: toFixed rounds the exact binary value, ties go away from zero, and |x| >= 1e21 prints like toString; every backend prints what node prints.

const cases: number[][] = [
	[2.9876, 1], [1.005, 2], [2.5, 0], [-2.5, 0], [0.5, 0], [1.5, 0], [-1.5, 0],
	[0.125, 2], [-0.0, 2], [-0.0001, 2], [1e21, 2], [1e20, 2], [1.2345678901234568e20, 2],
	[1.45, 1], [8.345, 2], [999.995, 2], [99.5, 0], [0, 0], [0.000001, 7],
	[0.1, 20], [5e-324, 20], [1.7976931348623157e308, 2], [NaN, 2], [Infinity, 1], [-Infinity, 0],
];
for (const c of cases) {
	console.log(`${c[0]} ${c[1]} ${c[0].toFixed(c[1] as int32)}`);
}
const d: number = 1.005;
console.log((2.9876).toFixed(1));
console.log(d.toFixed(2));
console.log((2.5).toFixed());
console.log((0.1).toFixed(100));
