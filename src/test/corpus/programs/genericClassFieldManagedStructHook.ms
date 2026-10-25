// Parity program — a generic class whose field is a generic struct with a
// managed member lifts hooks only for the instantiated types, never for the
// open template; the field initializer and a method both hold such a type.
//
// @stdout: done|none|7|none|spread:a,b
// @exit: 0

struct Failure<E> { error: E; exception: Error | null; }

class State<E> {
	failure: Failure<E> | null = null;
	note(): string {
		const probe: Failure<E> | null = null;
		return probe == null ? "none" : "some";
	}
}

class Cell<K> {
	names: HashSet<K> = new HashSet<K>();
	keys(): K[] { return [...this.names]; }
}

const out: string[] = [];
const s = new State<int32>();
out.push(s.failure == null ? "done" : "some");
out.push(s.note());
s.failure = { error: 7, exception: null };
out.push(s.failure != null ? `${s.failure.error}` : "gone");
const t = new State<string>();
out.push(t.note());
const c = new Cell<string>();
c.names.add("b");
c.names.add("a");
const ks = c.keys();
ks.sort();
out.push("spread:" + ks.join(","));
console.log(out.join("|"));
