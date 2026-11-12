import { el, NeonNode, dynAttr, dynText } from "./neon/src/render/node";
import { MockNode, mockHost, render } from "./neon/src/render/host";
import { ForList } from "./neon/src/macros/ui/flow";
import { createList, List } from "./neon/src/core/list";
import { Accessor, Setter, createSignal, accessor } from "./neon/src/core/signal";
import { flush } from "./neon/src/core/runtime";
import { element } from "./neon/src/macros/ui/element";

const ADJ = ["pretty", "large", "big", "small", "tall", "short", "long", "handsome", "plain", "quaint", "clean"];
const COL = ["red", "yellow", "blue", "green", "pink", "brown", "purple", "orange", "white", "black"];
const NOUN = ["table", "chair", "house", "bbq", "desk", "car", "pony", "cookie", "sandwich", "burger"];

class Row {
	id: number;
	label: Accessor<string>;
	setLabel: Setter<string>;
	constructor(id: number, text: string) {
		this.id = id;
		const [l, s] = createSignal<string>(text);
		this.label = l;
		this.setLabel = s;
	}
}

let nextId: number = 1;
let seed: int64 = 7;
function rnd(n: int32): int32 { seed = (seed * 1103515245 + 12345) % 2147483648; return (seed % (n as int64)) as int32; }

function build(n: number): Row[] {
	const out: Row[] = [];
	for (let i = 0; i < n; i += 1) {
		out.push(new Row(nextId, ADJ[rnd(11)] + " " + COL[rnd(10)] + " " + NOUN[rnd(10)]));
		nextId += 1;
	}
	return out;
}

const [selected, setSelected] = createSignal<number>(0);

function rowView(item: Accessor<Row>): NeonNode {
	const r = item();
	const id = "" + r.id;
	return el("tr", [dynAttr("class", (): string | null => selected() === r.id ? "danger" : "")], [], el("td", [], [], dynText((): string => id + " " + r.label())));
}

function countText(n: MockNode): number {
	let k: number = n.text.length;
	for (const c of n.children) { k += countText(c); }
	return k;
}

const rows: List<Row> = createList<Row>([]);
const host = mockHost();
const root = host.createElement("root");
const dispose = render(el("tbody", [], [], ForList<Row>({ each: rows, keyed: (r: Row): number => r.id, children: rowView })), host, root);

const ITER = 20;
let check: number = 0;
const t0 = performance.now();
for (let it = 0; it < ITER; it += 1) {
	rows.replaceAll(build(1000)); flush();
	const cur = rows.read();
	for (let i = 0; i < cur.length; i += 10) { cur[i].setLabel(cur[i].label() + " !!!"); }
	flush();
	for (let k = 0; k < 20; k += 1) { setSelected(cur[rnd(cur.length as int32)].id); flush(); }
	rows.move(1, rows.length() - 2); rows.move(rows.length() - 3, 1); flush();
	for (let k = 0; k < 20; k += 1) { rows.remove(rnd(rows.length() as int32)); flush(); }
	const more = build(1000);
	for (const r of more) { rows.push(r); }
	flush();
	check += countText(root as unknown as MockNode);
	rows.replaceAll([]); flush();
}
const ms = performance.now() - t0;
dispose();
console.log(`rows iter=${ITER} ms=${Math.round(ms)} check=${check}`);
