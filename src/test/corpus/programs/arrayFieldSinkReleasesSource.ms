// @stdout: 0 3 a
// @stdout: 4 b
// @stdout: 2 c
// note: an array of structs that hold references, moved into a field that already holds an array, leaves no array behind: the default `[]` replaced by a fresh one, a field reassigned from a local, and the generic instance of both
struct E { hcode: int32; key: string; }
struct G<K, V> { hcode: int32; key: K; value: V; }
class Holder { data: Vec<E> = []; size: int32 = 0; }
class Generic<K, V> { data: Vec<G<K, V>> = []; }

function viaDefault(): string {
	const h = new Holder();
	let fresh: Vec<E> = new Array(3);
	fresh[2].key = "a";
	h.data = fresh;
	return `${h.size} ${h.data.length} ${h.data[2].key}`;
}

function viaReassign(): string {
	const h = new Holder();
	for (let i: int32 = 1; i <= 4; i++) {
		let next: Vec<E> = new Array(i);
		next[i - 1].key = i == 4 ? "b" : "x";
		h.data = next;
	}
	return `${h.data.length} ${h.data[3].key}`;
}

function viaGeneric(): string {
	const g = new Generic<string, string>();
	let fresh: Vec<G<string, string>> = new Array(2);
	fresh[1].value = "c";
	g.data = fresh;
	return `${g.data.length} ${g.data[1].value}`;
}

for (let r = 0; r < 3; r++) {
	const a = viaDefault();
	const b = viaReassign();
	const c = viaGeneric();
	if (r == 2) {
		console.log(a);
		console.log(b);
		console.log(c);
	}
}
