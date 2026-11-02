@comptime
function primeCount(limit: number): number {
	const composite: boolean[] = [];
	for (let i = 0; i <= limit; i += 1) {
		composite.push(false);
	}
	let count = 0;
	for (let i = 2; i <= limit; i += 1) {
		if (!composite[i]) {
			count += 1;
			for (let j = i * 2; j <= limit; j += i) {
				composite[j] = true;
			}
		}
	}
	return count;
}

@comptime
function collatzBest(from: number, to: number): number {
	let best = 0;
	for (let start = from; start < to; start += 1) {
		let n = start;
		let steps = 0;
		while (n != 1) {
			if (n % 2 == 0) {
				n = n / 2;
			} else {
				n = n * 3 + 1;
			}
			steps += 1;
		}
		if (steps > best) {
			best = steps;
		}
	}
	return best;
}

@comptime
function digest(rounds: number): number {
	let text = "";
	for (let i = 0; i < rounds; i += 1) {
		text = text + "k" + i.toString();
	}
	let h = 17;
	for (let i = 0; i < text.length; i += 1) {
		h = (h * 31 + text.charCodeAt(i)) % 1000003;
	}
	return h;
}

const P1 = primeCount(300000);
const P2 = primeCount(310000);
const P3 = primeCount(320000);
const P4 = primeCount(330000);
const P5 = primeCount(340000);
const P6 = primeCount(350000);
const C1 = collatzBest(1, 20000);
const C2 = collatzBest(20000, 40000);
const C3 = collatzBest(40000, 60000);
const C4 = collatzBest(60000, 80000);
const C5 = collatzBest(80000, 100000);
const C6 = collatzBest(100000, 120000);
const D1 = digest(3000);
const D2 = digest(3100);
const D3 = digest(3200);
const D4 = digest(3300);

console.log(P1 + P2 + P3 + P4 + P5 + P6, C1 + C2 + C3 + C4 + C5 + C6, D1 + D2 + D3 + D4);
