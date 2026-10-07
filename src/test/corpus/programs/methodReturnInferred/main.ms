// @stdout: 5|7|fast
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
const out: string[] = [];
out.push(String(k.x));
out.push(String(k.twice(3)));
out.push(k.label(true));
console.log(out.join("|"));
