// An array or struct of plain values is a copy wherever it is stored, so it crosses an actor reply or a move
//
// INVARIANT (ULTRALOCK V2): `Vec<T>` and a struct hold their storage by value, so a literal field, a
//   spread of numbers, a call result or a value passed as an argument that is built only of such types has
//   no alias with its source. A reply built from them, and a binding of them moved to an actor, cross even when
//   the source is the actor's own state or a caller's local. A class reference inside is not a copy: the
//   same shapes with one stay refused (actorReplyStateRejects.ms).
//
// RED MEANS: the sole-owner check refuses a copy, or a write on one side reaches the other.
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

struct Row { table: int32; key: Vec<uint8>; }
struct Snap { version: int64; rows: Vec<Row>; }

function load(src: Readonly<Vec<Row>>): Vec<Row> {
	let out: Vec<Row> = [];
	for (const r of src) { out.push({ table: r.table, key: [...r.key] }); }
	return out;
}
function count(rows: Vec<Row>): int32 { return rows.length; }

actor Store {
	items: Vec<Row> = [{ table: 1, key: [7, 8] }];
	total: int64 = 0;
	fields(): Vec<Row> {
		let rows: Vec<Row> = [];
		for (const r of this.items) { rows.push({ table: r.table, key: r.key }); }
		return rows;
	}
	spread(): Vec<Row> {
		let rows: Vec<Row> = [];
		for (const r of this.items) { rows.push({ table: r.table, key: [...r.key] }); }
		return rows;
	}
	snapshot(): Snap {
		const rows = load(this.items);
		return { version: 1, rows: rows };
	}
	take(conn: Vec<uint8>, rows: Vec<Row>): int64 {
		this.total += conn.length + rows.length;
		return this.total;
	}
	firstKey(): int32 { return this.items[0].key[0]; }
}

async function send(store: Store, src: Readonly<Vec<Row>>, conn: Vec<uint8>): Promise<int64> {
	let owned: Vec<uint8> = [...conn];
	let known: Vec<Row> = [];
	for (const r of src) {
		let entry: Row = { table: r.table, key: [...r.key] };
		known.push(move entry);
	}
	return await store.take(move owned, move known);
}

async function sendAfterCount(store: Store): Promise<int64> {
	let image: Vec<Row> = [{ table: 1, key: [7] }];
	const n = count(image);
	return n + await store.take([1], move image);
}

async function main(): Promise<void> {
	const s = new Store();
	let a = await s.fields();
	let b = await s.spread();
	let c = await s.snapshot();
	a[0].key[0] = 99;
	b[0].key[0] = 98;
	c.rows[0].key[0] = 97;
	const sent = await send(s, a, [9, 9]);
	const counted = await sendAfterCount(s);
	const first = await s.firstKey();
	stop(s.pid, ExitReason.Normal);
	if (first != 7 || sent != 3 || counted != 6 || a.length != 1 || b.length != 1 || c.rows.length != 1) throw new Error(`value copies: first=${first} sent=${sent} counted=${counted}`);
	console.log("GUARD-OK");
}

await main();
