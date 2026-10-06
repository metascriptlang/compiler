// @stdout: 5\n7\nfast
// @exit: 0
// note: a class method with no return annotation takes its return type from its body, as a function does: no return is void, and a returned value sets the type. A call to such a method used to stop the C build with "unresolved type (kind=48) reached codegen".

class K {
	x: float32 = 0.0;
	put(v: float32) { this.x = v; }
	twice(n: int32) { return n * 2 + 1; }
	label(fast: boolean) {
		if (fast) return "fast";
		return "slow";
	}
}

const k = new K();
k.put(5.0);
console.log(String(k.x));
console.log(String(k.twice(3)));
console.log(k.label(true));
