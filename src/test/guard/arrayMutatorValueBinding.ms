// GUARD-CHECK-FAIL cannot mutate value-type parameter 'v'
// GUARD-CHECK-FAIL cannot mutate value-type parameter 'w'
// GUARD-CHECK-FAIL cannot mutate value-type loop variable 'p'

function f(v: Vec<int32>): int32 {
	v.push(1);
	return v.length;
}

function g(w: Vec<float64>): int32 {
	w.sort();
	return w.length;
}

function h(vv: Vec<Vec<int32>>): int32 {
	for (const p of vv) {
		p.push(7);
	}
	return vv.length;
}
