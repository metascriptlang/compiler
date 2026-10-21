// nim-guard: asyncfutures.nim `all` — the result is an ordinary seq[T], released by
// seq[T]'s own =destroy. A Promise.all result array must drop its elements through
// the element type's array destroy, whatever the element: a closure releases its
// environment, a class-or-int union and a tuple release the class they hold.
// Red signature: the result cell frees its payload with the number-array destroy,
// so every collected closure env (and every Box inside a union or tuple) leaks.
// GUARD-BALANCE dollarEnv_counter_shared_
// GUARD-BALANCE Box

class Box { v: int32 = 0; }
type Count = () => int32;

async function counter(start: int32): Promise<Count> {
	let seen = start;
	return (): int32 => { seen = seen + 1; return seen; };
}
async function boxOrInt(n: int32): Promise<Box | int32> {
	if (n > 0) { const b = new Box(); b.v = n; return b; }
	return n;
}
async function pair(n: int32): Promise<[Box, int32]> { const b = new Box(); b.v = n; return [b, n]; }

function boxOrIntValue(u: Box | int32): int32 {
	if (u instanceof Box) return u.v;
	return u;
}

async function closures(): Promise<int32> {
	let sum = 0;
	for (let i = 0; i < 20; i += 1) {
		const cs = await Promise.all([counter(i), counter(i)]);
		sum += cs[0]() + cs[1]();
	}
	return sum;
}

async function values(): Promise<int32> {
	let sum = 0;
	for (let i = 0; i < 20; i += 1) {
		const us = await Promise.all([boxOrInt(i + 1), boxOrInt(-i)]);
		sum += us.length + boxOrIntValue(us[0]) + boxOrIntValue(us[1]);
		const ps = await Promise.all([pair(i), pair(i + 1)]);
		sum += ps[0][0].v + ps[1][1];
	}
	return sum;
}

console.log(`closures ${await closures()} values ${await values()}`);
