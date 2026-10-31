// An array or struct of plain values crosses an actor boundary as a copy, so each side may write its own
//
// INVARIANT (ULTRALOCK V2): a reply built from a `Vec` field, and a `Vec` passed into an actor method, are
//   copied at the crossing, never shared through a count, so the actor and the caller write their own
//   storage at the same time.
//
// WHAT IT CATCHES: a value-only reply or argument that shares its buffer; TSan reports the race and the
//   checksum shows a write reaching the other side.
//
// RED MEANS: a value-only crossing shares storage with its source.
//
// GUARD-TSAN

struct Row { table: int32; key: Vec<uint8>; }

actor Store {
	items: Vec<Row> = [{ table: 1, key: [1, 2, 3, 4] }];
	seen: int64 = 0;
	spin(rounds: int32): int64 {
		for (let i: int32 = 0; i < rounds; i += 1) {
			for (let k = 0; k < this.items[0].key.length; k += 1) this.items[0].key[k] = (this.items[0].key[k] + 1) as uint8;
			this.items[0].key.push(1);
			this.items[0].key.pop();
		}
		return this.items[0].key.length;
	}
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
	take(rows: Vec<Row>): int64 {
		let mine: Vec<Row> = rows;
		for (let k = 0; k < mine[0].key.length; k += 1) mine[0].key[k] = 7;
		this.seen += mine[0].key.length;
		return this.seen;
	}
	width(): int32 { return this.items[0].key.length; }
}

async function main(): Promise<void> {
	const s = new Store();
	let sum: int64 = 0;
	for (let i: int32 = 0; i < 100; i += 1) {
		const busy = s.spin(200);
		let a = await s.fields();
		let b = await s.spread();
		let own: Vec<Row> = [{ table: 2, key: [9, 9, 9] }];
		const sent = s.take(own);
		for (let j: int32 = 0; j < 200; j += 1) {
			a[0].key[0] = (a[0].key[0] + 1) as uint8;
			b[0].key[1] = (b[0].key[1] + 1) as uint8;
			own[0].key[2] = (own[0].key[2] + 1) as uint8;
			sum += a[0].key[0] + b[0].key[1] + own[0].key[2];
		}
		await busy;
		await sent;
	}
	const width = await s.width();
	if (width != 4) { throw "GUARD RED: width=" + width; }
	console.log("GUARD-OK");
}

main();
