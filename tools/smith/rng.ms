export class Rng {
	state: uint64 = 0 as uint64;

	next(): uint64 {
		this.state = this.state + (0x9E3779B97F4A7C15 as uint64);
		let z = this.state;
		z = (z ^ (z >> (30 as uint64))) * (0xBF58476D1CE4E5B9 as uint64);
		z = (z ^ (z >> (27 as uint64))) * (0x94D049BB133111EB as uint64);
		return z ^ (z >> (31 as uint64));
	}

	below(n: int32): int32 {
		if (n <= 0) { unreachable; }
		return (this.next() % (n as uint64)) as int32;
	}

	chance(percent: int32): boolean {
		return this.below(100) < percent;
	}

	between(low: int32, high: int32): int32 {
		return low + this.below(high - low + 1);
	}
}

export function seeded(this typeof Rng, seed: uint64): Rng {
	const r = new Rng();
	r.state = seed;
	return r;
}

test "splitmix64 matches the reference stream for seed 0" {
	const r = Rng.seeded(0 as uint64);
	assert r.next() == (16294208416658607535 as uint64);
	assert r.next() == (7960286522194355700 as uint64);
	assert r.next() == (487617019471545679 as uint64);
}

test "splitmix64 matches the reference stream for seed 42" {
	const r = Rng.seeded(42 as uint64);
	assert r.next() == (13679457532755275413 as uint64);
}

test "below stays inside its bound" {
	const r = Rng.seeded(7 as uint64);
	for (let i = 0; i < 1000; i++) {
		const v = r.below(5);
		assert v >= 0 && v < 5;
	}
}
