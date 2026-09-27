const third: number = 1.0 / 3.0;
const values: number[] = [
	0.1,
	0.1 + 0.2,
	third,
	1e21,
	1e-7,
	123456.789,
	-0.0000015,
	5e-324,
	1.7976931348623157e308,
	7.120236347223045e-307,
	5.351097043477547e-197,
	8.209073602596753e-289,
	1152921504606846976.0,
	NaN,
	-Infinity,
];
for (const value of values) {
	console.log(value.toString());
}
