// @stdout: 8
// @stdout: a
// @stdout: 16
// @stdout: 4 0
// note: moving an array out of a field leaves the field an empty array that a later store refills, and the moved array keeps its length and elements; the generic enlarge swaps the slot array this way, and the last line moves out and reads the emptied field
struct E<K, V> { h: int64; k: K; v: V; }
class M<K, V> { data: Vec<E<K, V>>; size: int32; }
function enlarge<K, V>(m: M<K, V>): void {
	let oldData = move m.data;
	const newCap = oldData.length * 2;
	const newData: Vec<E<K, V>> = new Array(newCap);
	m.data = newData;
	let i: int32 = 0;
	while (i < oldData.length) {
		if (oldData[i].h != 0) {
			let j: int32 = (oldData[i].h & ((newCap - 1) as int64)) as int32;
			while (m.data[j].h != 0) { j = (j + 1) & (newCap - 1); }
			m.data[j].h = oldData[i].h;
			m.data[j].k = move oldData[i].k;
			m.data[j].v = move oldData[i].v;
		}
		i = i + 1;
	}
}
function takeAndMeasure(m: M<string, string>): void {
	const taken = move m.data;
	console.log(`${taken.length} ${m.data.length}`);
}
function main(): void {
	const m = new M<string, string>();
	const init: Vec<E<string, string>> = new Array(4);
	m.data = init;
	m.data[1].h = 5; m.data[1].k = "a"; m.data[1].v = "b";
	enlarge(m);
	console.log(m.data.length);
	console.log(m.data[5].k);
	enlarge(m);
	console.log(m.data.length);
	const n = new M<string, string>();
	const init2: Vec<E<string, string>> = new Array(4);
	n.data = init2;
	takeAndMeasure(n);
}
main();
