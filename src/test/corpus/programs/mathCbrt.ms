// @stdout: math cbrt done

function show(v: float64): string {
	return v == 0.0 && Math.atan2(v, -1.0) < 0.0 ? "-0" : `${v}`;
}

let failures = 0;

const cbrtInputs: float64[] = [
	27.0,
	8.0,
	64.0,
	1000.0,
	-27.0,
	0.0,
	-0.0,
	Number.POSITIVE_INFINITY,
	Number.NEGATIVE_INFINITY,
	Number.NaN,
	5e-324,
	-1e-310,
	2.2250738585072014e-308,
	2.0,
	3.0,
	1e+300,
	1e-300,
	0.001,
	-0.125,
	1.7976931348623157e+308,
	123456789.0,
];
const cbrtWant: string[] = [
	"3",
	"2",
	"4",
	"10",
	"-3",
	"0",
	"-0",
	"Infinity",
	"-Infinity",
	"NaN",
	"1.7031839360032603e-108",
	"-4.641588833612774e-104",
	"2.812644285236262e-103",
	"1.2599210498948732",
	"1.4422495703074083",
	"1e+100",
	"1e-100",
	"0.1",
	"-0.5",
	"5.643803094122362e+102",
	"497.93385921817446",
];

for (let i = 0; i < cbrtInputs.length; i++) {
	const got = show(Math.cbrt(cbrtInputs[i]));
	console.log(`cbrt(${show(cbrtInputs[i])}) = ${got}`);
	if (got != cbrtWant[i]) {
		console.log(`FAIL Math.cbrt[${i}] got ${got} want ${cbrtWant[i]}`);
		failures += 1;
	}
}
console.log(failures == 0 ? "math cbrt done" : `${failures} failures`);
