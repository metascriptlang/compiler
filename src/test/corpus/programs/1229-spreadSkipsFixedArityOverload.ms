// @stdout: 9 5 3 9
function mx(a: float64, b: float64): float64 {
	return a > b ? a : b;
}

function mx(...v: float64[]): float64 {
	let r = -Infinity;
	for (const x of v) {
		if (x > r) r = x;
	}
	return r;
}

const xs: number[] = [3, 9, 1];
console.log(mx(...xs), mx(4, 5), mx(1, 2, 3), mx(7, ...xs));
