// @stdout: I32 run 97 skipped 103 mismatches 0
// @stdout: I8 run 56 skipped 64 mismatches 0
// @stdout: I16 run 53 skipped 67 mismatches 0
// @stdout: I64 run 70 skipped 50 mismatches 0
// @stdout: I64I32 run 118 skipped 2 mismatches 0
// @stdout: I32I8 run 114 skipped 6 mismatches 0
// @stdout: dotI8 run 17 skipped 103 mismatches 0
// @stdout: dotI16 run 45 skipped 75 mismatches 0
// @stdout: dotI32 run 53 skipped 107 mismatches 0
// @stdout: dotI64 run 117 skipped 3 mismatches 0
// note: a fixed-seed differential fuzz. Edge-biased random arrays, lengths up to 3000 (several blocks of 1024), are reduced by the
// for-of and indexed reduction loops, sums at every width, widening sums and dot products, += and -=, and compared with a
// loop of `s = s + x` and with an exact prediction; an array whose prediction leaves the accumulator's range is counted, not run.

interface Exact { ok: boolean; v: int64 }

let seed: int64 = 20261016;

function rnd(): int64 {
	seed = seed * 48271 % 2147483647;
	return seed;
}

function pow2(k: int64): int64 {
	let p: int64 = 1;
	for (let i: int64 = 0; i < k; i++) p = p * 2;
	return p;
}

function full64(): int64 {
	return (rnd() - 1073741824) * 8589934592 + rnd() * 4 + rnd() % 4;
}

function pick(bits: int64, max: int64, min: int64): int64 {
	const mode = rnd() % 5;
	if (mode == 1) return rnd() % 21 - 10;
	if (mode == 2) {
		const e = rnd() % 7;
		if (e == 0) return max;
		if (e == 1) return min;
		if (e == 2) return max - 1;
		if (e == 3) return min + 1;
		return e - 5;
	}
	const v = bits == 64 ? full64() : (rnd() * 2147483647 + rnd()) % (max - min + 1) + min;
	if (mode == 3) {
		const lim = max / 2048 + 1;
		return (rnd() * 2147483647 + rnd()) % (2 * lim + 1) - lim;
	}
	if (mode == 4) return v / pow2(rnd() % (bits - 1));
	return v;
}

function biased(bits: int64, max: int64, min: int64): int64 {
	return rnd() % 3 == 0 ? pick(bits, max, min) : rnd() % 21 - 10;
}

function rare(bits: int64, max: int64, min: int64): int64 {
	return rnd() % 8 == 0 ? pick(bits, max, min) : rnd() % 21 - 10;
}

function lengthAt(t: int32): int64 {
	return rnd() % (t % 10 == 0 ? 3000 : 40);
}

function fits(v: int64, max: int64, min: int64): boolean {
	return v >= min && v <= max;
}

function addExact(s: int64, x: int64, sub: boolean): Exact {
	if (!sub && ((x > 0 && s > 9223372036854775807 - x) || (x < 0 && s < -9223372036854775807 - 1 - x))) return { ok: false, v: 0 };
	if (sub && ((x < 0 && s > 9223372036854775807 + x) || (x > 0 && s < -9223372036854775807 - 1 + x))) return { ok: false, v: 0 };
	return { ok: true, v: sub ? s - x : s + x };
}


function ofI32Add(xs: int32[], acc: int32): int32 {
	let s: int32 = acc;
	for (const x of xs) s += x;
	return s;
}

function atI32Add(xs: int32[], acc: int32): int32 {
	let s: int32 = acc;
	for (let i = 0; i < xs.length; i++) s += xs[i];
	return s;
}

function refI32Add(xs: int32[], acc: int32): int32 {
	let s: int32 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s + xs[i];
	}
	return s;
}

function ofI32Sub(xs: int32[], acc: int32): int32 {
	let s: int32 = acc;
	for (const x of xs) s -= x;
	return s;
}

function atI32Sub(xs: int32[], acc: int32): int32 {
	let s: int32 = acc;
	for (let i = 0; i < xs.length; i++) s -= xs[i];
	return s;
}

function refI32Sub(xs: int32[], acc: int32): int32 {
	let s: int32 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s - xs[i];
	}
	return s;
}

function fuzzI32(cases: int32): void {
	let run = 0;
	let skipped = 0;
	let bad = 0;
	for (let t = 0; t < cases; t++) {
		const n = lengthAt(t);
		const xs: int32[] = [];
		for (let i: int64 = 0; i < n; i++) xs.push(biased(32, 2147483647, -2147483648) as int32);
		const acc = biased(32, 2147483647, -2147483648) as int32;
		const sub = rnd() % 2 == 1;
		let e: Exact = { ok: true, v: acc as int64 };
		for (const x of xs) {
			if (e.ok) e = addExact(e.v, x as int64, sub);
			if (e.ok && !fits(e.v, 2147483647, -2147483648)) e = { ok: false, v: 0 };
		}
		if (!e.ok) {
			skipped++;
			continue;
		}
		run++;
		const want = e.v as int32;
		if (!sub && (refI32Add(xs, acc) != want || ofI32Add(xs, acc) != want || atI32Add(xs, acc) != want)) bad++;
		if (sub && (refI32Sub(xs, acc) != want || ofI32Sub(xs, acc) != want || atI32Sub(xs, acc) != want)) bad++;
	}
	console.log(`I32 run ${run} skipped ${skipped} mismatches ${bad}`);
}

function ofI8Add(xs: int8[], acc: int8): int8 {
	let s: int8 = acc;
	for (const x of xs) s += x;
	return s;
}

function atI8Add(xs: int8[], acc: int8): int8 {
	let s: int8 = acc;
	for (let i = 0; i < xs.length; i++) s += xs[i];
	return s;
}

function refI8Add(xs: int8[], acc: int8): int8 {
	let s: int8 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s + xs[i];
	}
	return s;
}

function ofI8Sub(xs: int8[], acc: int8): int8 {
	let s: int8 = acc;
	for (const x of xs) s -= x;
	return s;
}

function atI8Sub(xs: int8[], acc: int8): int8 {
	let s: int8 = acc;
	for (let i = 0; i < xs.length; i++) s -= xs[i];
	return s;
}

function refI8Sub(xs: int8[], acc: int8): int8 {
	let s: int8 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s - xs[i];
	}
	return s;
}

function fuzzI8(cases: int32): void {
	let run = 0;
	let skipped = 0;
	let bad = 0;
	for (let t = 0; t < cases; t++) {
		const n = lengthAt(t);
		const xs: int8[] = [];
		for (let i: int64 = 0; i < n; i++) xs.push(biased(8, 127, -128) as int8);
		const acc = biased(8, 127, -128) as int8;
		const sub = rnd() % 2 == 1;
		let e: Exact = { ok: true, v: acc as int64 };
		for (const x of xs) {
			if (e.ok) e = addExact(e.v, x as int64, sub);
			if (e.ok && !fits(e.v, 127, -128)) e = { ok: false, v: 0 };
		}
		if (!e.ok) {
			skipped++;
			continue;
		}
		run++;
		const want = e.v as int8;
		if (!sub && (refI8Add(xs, acc) != want || ofI8Add(xs, acc) != want || atI8Add(xs, acc) != want)) bad++;
		if (sub && (refI8Sub(xs, acc) != want || ofI8Sub(xs, acc) != want || atI8Sub(xs, acc) != want)) bad++;
	}
	console.log(`I8 run ${run} skipped ${skipped} mismatches ${bad}`);
}

function ofI16Add(xs: int16[], acc: int16): int16 {
	let s: int16 = acc;
	for (const x of xs) s += x;
	return s;
}

function atI16Add(xs: int16[], acc: int16): int16 {
	let s: int16 = acc;
	for (let i = 0; i < xs.length; i++) s += xs[i];
	return s;
}

function refI16Add(xs: int16[], acc: int16): int16 {
	let s: int16 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s + xs[i];
	}
	return s;
}

function ofI16Sub(xs: int16[], acc: int16): int16 {
	let s: int16 = acc;
	for (const x of xs) s -= x;
	return s;
}

function atI16Sub(xs: int16[], acc: int16): int16 {
	let s: int16 = acc;
	for (let i = 0; i < xs.length; i++) s -= xs[i];
	return s;
}

function refI16Sub(xs: int16[], acc: int16): int16 {
	let s: int16 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s - xs[i];
	}
	return s;
}

function fuzzI16(cases: int32): void {
	let run = 0;
	let skipped = 0;
	let bad = 0;
	for (let t = 0; t < cases; t++) {
		const n = lengthAt(t);
		const xs: int16[] = [];
		for (let i: int64 = 0; i < n; i++) xs.push(biased(16, 32767, -32768) as int16);
		const acc = biased(16, 32767, -32768) as int16;
		const sub = rnd() % 2 == 1;
		let e: Exact = { ok: true, v: acc as int64 };
		for (const x of xs) {
			if (e.ok) e = addExact(e.v, x as int64, sub);
			if (e.ok && !fits(e.v, 32767, -32768)) e = { ok: false, v: 0 };
		}
		if (!e.ok) {
			skipped++;
			continue;
		}
		run++;
		const want = e.v as int16;
		if (!sub && (refI16Add(xs, acc) != want || ofI16Add(xs, acc) != want || atI16Add(xs, acc) != want)) bad++;
		if (sub && (refI16Sub(xs, acc) != want || ofI16Sub(xs, acc) != want || atI16Sub(xs, acc) != want)) bad++;
	}
	console.log(`I16 run ${run} skipped ${skipped} mismatches ${bad}`);
}

function ofI64Add(xs: int64[], acc: int64): int64 {
	let s: int64 = acc;
	for (const x of xs) s += x;
	return s;
}

function atI64Add(xs: int64[], acc: int64): int64 {
	let s: int64 = acc;
	for (let i = 0; i < xs.length; i++) s += xs[i];
	return s;
}

function refI64Add(xs: int64[], acc: int64): int64 {
	let s: int64 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s + xs[i];
	}
	return s;
}

function ofI64Sub(xs: int64[], acc: int64): int64 {
	let s: int64 = acc;
	for (const x of xs) s -= x;
	return s;
}

function atI64Sub(xs: int64[], acc: int64): int64 {
	let s: int64 = acc;
	for (let i = 0; i < xs.length; i++) s -= xs[i];
	return s;
}

function refI64Sub(xs: int64[], acc: int64): int64 {
	let s: int64 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s - xs[i];
	}
	return s;
}

function fuzzI64(cases: int32): void {
	let run = 0;
	let skipped = 0;
	let bad = 0;
	for (let t = 0; t < cases; t++) {
		const n = lengthAt(t);
		const xs: int64[] = [];
		for (let i: int64 = 0; i < n; i++) xs.push(biased(64, 9223372036854775807, -9223372036854775808) as int64);
		const acc = biased(64, 9223372036854775807, -9223372036854775808) as int64;
		const sub = rnd() % 2 == 1;
		let e: Exact = { ok: true, v: acc as int64 };
		for (const x of xs) {
			if (e.ok) e = addExact(e.v, x as int64, sub);
			if (e.ok && !fits(e.v, 9223372036854775807, -9223372036854775808)) e = { ok: false, v: 0 };
		}
		if (!e.ok) {
			skipped++;
			continue;
		}
		run++;
		const want = e.v as int64;
		if (!sub && (refI64Add(xs, acc) != want || ofI64Add(xs, acc) != want || atI64Add(xs, acc) != want)) bad++;
		if (sub && (refI64Sub(xs, acc) != want || ofI64Sub(xs, acc) != want || atI64Sub(xs, acc) != want)) bad++;
	}
	console.log(`I64 run ${run} skipped ${skipped} mismatches ${bad}`);
}

function ofI64I32Add(xs: int32[], acc: int64): int64 {
	let s: int64 = acc;
	for (const x of xs) s += x;
	return s;
}

function refI64I32Add(xs: int32[], acc: int64): int64 {
	let s: int64 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s + xs[i];
	}
	return s;
}

function ofI64I32Sub(xs: int32[], acc: int64): int64 {
	let s: int64 = acc;
	for (const x of xs) s -= x;
	return s;
}

function refI64I32Sub(xs: int32[], acc: int64): int64 {
	let s: int64 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s - xs[i];
	}
	return s;
}

function fuzzI64I32(cases: int32): void {
	let run = 0;
	let skipped = 0;
	let bad = 0;
	for (let t = 0; t < cases; t++) {
		const n = lengthAt(t);
		const xs: int32[] = [];
		for (let i: int64 = 0; i < n; i++) xs.push(biased(32, 2147483647, -2147483648) as int32);
		const acc = biased(64, 9223372036854775807, -9223372036854775808) as int64;
		const sub = rnd() % 2 == 1;
		let e: Exact = { ok: true, v: acc as int64 };
		for (const x of xs) {
			if (e.ok) e = addExact(e.v, x as int64, sub);
			if (e.ok && !fits(e.v, 9223372036854775807, -9223372036854775808)) e = { ok: false, v: 0 };
		}
		if (!e.ok) {
			skipped++;
			continue;
		}
		run++;
		const want = e.v as int64;
		if (!sub && (refI64I32Add(xs, acc) != want || ofI64I32Add(xs, acc) != want)) bad++;
		if (sub && (refI64I32Sub(xs, acc) != want || ofI64I32Sub(xs, acc) != want)) bad++;
	}
	console.log(`I64I32 run ${run} skipped ${skipped} mismatches ${bad}`);
}

function atI32I8Add(xs: int8[], acc: int32): int32 {
	let s: int32 = acc;
	for (let i = 0; i < xs.length; i++) s += xs[i];
	return s;
}

function refI32I8Add(xs: int8[], acc: int32): int32 {
	let s: int32 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s + xs[i];
	}
	return s;
}

function atI32I8Sub(xs: int8[], acc: int32): int32 {
	let s: int32 = acc;
	for (let i = 0; i < xs.length; i++) s -= xs[i];
	return s;
}

function refI32I8Sub(xs: int8[], acc: int32): int32 {
	let s: int32 = acc;
	for (let i = 0; i < xs.length; i++) {
		s = s - xs[i];
	}
	return s;
}

function fuzzI32I8(cases: int32): void {
	let run = 0;
	let skipped = 0;
	let bad = 0;
	for (let t = 0; t < cases; t++) {
		const n = lengthAt(t);
		const xs: int8[] = [];
		for (let i: int64 = 0; i < n; i++) xs.push(biased(8, 127, -128) as int8);
		const acc = biased(32, 2147483647, -2147483648) as int32;
		const sub = rnd() % 2 == 1;
		let e: Exact = { ok: true, v: acc as int64 };
		for (const x of xs) {
			if (e.ok) e = addExact(e.v, x as int64, sub);
			if (e.ok && !fits(e.v, 2147483647, -2147483648)) e = { ok: false, v: 0 };
		}
		if (!e.ok) {
			skipped++;
			continue;
		}
		run++;
		const want = e.v as int32;
		if (!sub && (refI32I8Add(xs, acc) != want || atI32I8Add(xs, acc) != want)) bad++;
		if (sub && (refI32I8Sub(xs, acc) != want || atI32I8Sub(xs, acc) != want)) bad++;
	}
	console.log(`I32I8 run ${run} skipped ${skipped} mismatches ${bad}`);
}

function dotI8Add(a: int8[], b: int8[], acc: int8): int8 {
	let s: int8 = acc;
	for (let k = 0; k < a.length; k++) s += a[k] * b[k];
	return s;
}

function refDotI8Add(a: int8[], b: int8[], acc: int8): int8 {
	let s: int8 = acc;
	for (let k = 0; k < a.length; k++) {
		s = s + a[k] * b[k];
	}
	return s;
}

function dotI8Sub(a: int8[], b: int8[], acc: int8): int8 {
	let s: int8 = acc;
	for (let k = 0; k < a.length; k++) s -= a[k] * b[k];
	return s;
}

function refDotI8Sub(a: int8[], b: int8[], acc: int8): int8 {
	let s: int8 = acc;
	for (let k = 0; k < a.length; k++) {
		s = s - a[k] * b[k];
	}
	return s;
}

function fuzzDotI8(cases: int32): void {
	let run = 0;
	let skipped = 0;
	let bad = 0;
	for (let t = 0; t < cases; t++) {
		const n = lengthAt(t);
		const a: int8[] = [];
		const b: int8[] = [];
		for (let i: int64 = 0; i < n; i++) {
			a.push(rare(8, 127, -128) as int8);
			b.push(rare(8, 127, -128) as int8);
		}
		const acc = biased(8, 127, -128) as int8;
		const sub = rnd() % 2 == 1;
		let e: Exact = { ok: true, v: acc as int64 };
		for (let k = 0; k < a.length; k++) {
			const p = (a[k] as int64) * (b[k] as int64);
			if (e.ok && !fits(p, 127, -128)) e = { ok: false, v: 0 };
			if (e.ok) e = addExact(e.v, p, sub);
			if (e.ok && !fits(e.v, 127, -128)) e = { ok: false, v: 0 };
		}
		if (!e.ok) {
			skipped++;
			continue;
		}
		run++;
		const want = e.v as int8;
		if (!sub && (dotI8Add(a, b, acc) != want || refDotI8Add(a, b, acc) != want)) bad++;
		if (sub && (dotI8Sub(a, b, acc) != want || refDotI8Sub(a, b, acc) != want)) bad++;
	}
	console.log(`dotI8 run ${run} skipped ${skipped} mismatches ${bad}`);
}

function dotI16Add(a: int16[], b: int16[], acc: int16): int16 {
	let s: int16 = acc;
	for (let k = 0; k < a.length; k++) s += a[k] * b[k];
	return s;
}

function refDotI16Add(a: int16[], b: int16[], acc: int16): int16 {
	let s: int16 = acc;
	for (let k = 0; k < a.length; k++) {
		s = s + a[k] * b[k];
	}
	return s;
}

function dotI16Sub(a: int16[], b: int16[], acc: int16): int16 {
	let s: int16 = acc;
	for (let k = 0; k < a.length; k++) s -= a[k] * b[k];
	return s;
}

function refDotI16Sub(a: int16[], b: int16[], acc: int16): int16 {
	let s: int16 = acc;
	for (let k = 0; k < a.length; k++) {
		s = s - a[k] * b[k];
	}
	return s;
}

function fuzzDotI16(cases: int32): void {
	let run = 0;
	let skipped = 0;
	let bad = 0;
	for (let t = 0; t < cases; t++) {
		const n = lengthAt(t);
		const a: int16[] = [];
		const b: int16[] = [];
		for (let i: int64 = 0; i < n; i++) {
			a.push(rare(16, 32767, -32768) as int16);
			b.push(rare(16, 32767, -32768) as int16);
		}
		const acc = biased(16, 32767, -32768) as int16;
		const sub = rnd() % 2 == 1;
		let e: Exact = { ok: true, v: acc as int64 };
		for (let k = 0; k < a.length; k++) {
			const p = (a[k] as int64) * (b[k] as int64);
			if (e.ok && !fits(p, 32767, -32768)) e = { ok: false, v: 0 };
			if (e.ok) e = addExact(e.v, p, sub);
			if (e.ok && !fits(e.v, 32767, -32768)) e = { ok: false, v: 0 };
		}
		if (!e.ok) {
			skipped++;
			continue;
		}
		run++;
		const want = e.v as int16;
		if (!sub && (dotI16Add(a, b, acc) != want || refDotI16Add(a, b, acc) != want)) bad++;
		if (sub && (dotI16Sub(a, b, acc) != want || refDotI16Sub(a, b, acc) != want)) bad++;
	}
	console.log(`dotI16 run ${run} skipped ${skipped} mismatches ${bad}`);
}

function dotI32Add(a: int32[], b: int32[], acc: int32): int32 {
	let s: int32 = acc;
	for (let k = 0; k < a.length; k++) s += a[k] * b[k];
	return s;
}

function refDotI32Add(a: int32[], b: int32[], acc: int32): int32 {
	let s: int32 = acc;
	for (let k = 0; k < a.length; k++) {
		s = s + a[k] * b[k];
	}
	return s;
}

function dotI32Sub(a: int32[], b: int32[], acc: int32): int32 {
	let s: int32 = acc;
	for (let k = 0; k < a.length; k++) s -= a[k] * b[k];
	return s;
}

function refDotI32Sub(a: int32[], b: int32[], acc: int32): int32 {
	let s: int32 = acc;
	for (let k = 0; k < a.length; k++) {
		s = s - a[k] * b[k];
	}
	return s;
}

function fuzzDotI32(cases: int32): void {
	let run = 0;
	let skipped = 0;
	let bad = 0;
	for (let t = 0; t < cases; t++) {
		const n = lengthAt(t);
		const a: int32[] = [];
		const b: int32[] = [];
		for (let i: int64 = 0; i < n; i++) {
			a.push(rare(32, 2147483647, -2147483648) as int32);
			b.push(rare(32, 2147483647, -2147483648) as int32);
		}
		const acc = biased(32, 2147483647, -2147483648) as int32;
		const sub = rnd() % 2 == 1;
		let e: Exact = { ok: true, v: acc as int64 };
		for (let k = 0; k < a.length; k++) {
			const p = (a[k] as int64) * (b[k] as int64);
			if (e.ok && !fits(p, 2147483647, -2147483648)) e = { ok: false, v: 0 };
			if (e.ok) e = addExact(e.v, p, sub);
			if (e.ok && !fits(e.v, 2147483647, -2147483648)) e = { ok: false, v: 0 };
		}
		if (!e.ok) {
			skipped++;
			continue;
		}
		run++;
		const want = e.v as int32;
		if (!sub && (dotI32Add(a, b, acc) != want || refDotI32Add(a, b, acc) != want)) bad++;
		if (sub && (dotI32Sub(a, b, acc) != want || refDotI32Sub(a, b, acc) != want)) bad++;
	}
	console.log(`dotI32 run ${run} skipped ${skipped} mismatches ${bad}`);
}

function dotI64Add(a: int64[], b: int64[], acc: int64): int64 {
	let s: int64 = acc;
	for (let k = 0; k < a.length; k++) s += a[k] * b[k];
	return s;
}

function refDotI64Add(a: int64[], b: int64[], acc: int64): int64 {
	let s: int64 = acc;
	for (let k = 0; k < a.length; k++) {
		s = s + a[k] * b[k];
	}
	return s;
}

function dotI64Sub(a: int64[], b: int64[], acc: int64): int64 {
	let s: int64 = acc;
	for (let k = 0; k < a.length; k++) s -= a[k] * b[k];
	return s;
}

function refDotI64Sub(a: int64[], b: int64[], acc: int64): int64 {
	let s: int64 = acc;
	for (let k = 0; k < a.length; k++) {
		s = s - a[k] * b[k];
	}
	return s;
}

function fuzzDotI64(cases: int32): void {
	let run = 0;
	let skipped = 0;
	let bad = 0;
	for (let t = 0; t < cases; t++) {
		const n = lengthAt(t);
		const a: int64[] = [];
		const b: int64[] = [];
		for (let i: int64 = 0; i < n; i++) {
			a.push(rare(32, 2147483647, -2147483648) as int64);
			b.push(rare(32, 2147483647, -2147483648) as int64);
		}
		const acc = biased(64, 9223372036854775807, -9223372036854775808) as int64;
		const sub = rnd() % 2 == 1;
		let e: Exact = { ok: true, v: acc as int64 };
		for (let k = 0; k < a.length; k++) {
			const p = (a[k] as int64) * (b[k] as int64);
			if (e.ok && !fits(p, 9223372036854775807, -9223372036854775808)) e = { ok: false, v: 0 };
			if (e.ok) e = addExact(e.v, p, sub);
			if (e.ok && !fits(e.v, 9223372036854775807, -9223372036854775808)) e = { ok: false, v: 0 };
		}
		if (!e.ok) {
			skipped++;
			continue;
		}
		run++;
		const want = e.v as int64;
		if (!sub && (dotI64Add(a, b, acc) != want || refDotI64Add(a, b, acc) != want)) bad++;
		if (sub && (dotI64Sub(a, b, acc) != want || refDotI64Sub(a, b, acc) != want)) bad++;
	}
	console.log(`dotI64 run ${run} skipped ${skipped} mismatches ${bad}`);
}

function main(): void {
	fuzzI32(200);
	fuzzI8(120);
	fuzzI16(120);
	fuzzI64(120);
	fuzzI64I32(120);
	fuzzI32I8(120);
	fuzzDotI8(120);
	fuzzDotI16(120);
	fuzzDotI32(160);
	fuzzDotI64(120);
}

main();
