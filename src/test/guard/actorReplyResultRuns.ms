// An actor replies with a Result wrapping a fresh value, and the caller's writes stay its own
//
// INVARIANT (ULTRALOCK V2): `Result.ok(v)` and `Result.err(e)` build no alias of their argument, so a
//   Result reply is as fresh as its payload: a local built for the reply, `new`, a literal, a template
//   string. A payload that is the actor's own state is refused: actorReplyStateRejects.ms.
//
// RED MEANS: the reply rule refuses a Result of a fresh value.
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

class Node { hits: int32 = 0; }
struct Row { table: int32; key: Vec<uint8>; }

actor Scene {
	count: int32 = 3;
	top: Node = new Node();
	rows(fail: boolean): Result<Vec<int32>, string> {
		if (fail) { return Result.err(`refused ${this.count}`); }
		let rows: Vec<int32> = [];
		rows.push(this.count);
		return Result.ok(rows);
	}
	node(): Result<Node, string> { return Result.ok(new Node()); }
	copy(): Result<Node, string> {
		const n = new Node();
		n.hits = this.top.hits;
		return Result.ok(n);
	}
	bound(): Result<Vec<Row>, string> {
		let rows: Vec<Row> = [{ table: 1, key: [1] }];
		const result: Result<Vec<Row>, string> = Result.ok(move rows);
		return result;
	}
}

async function main(): Promise<void> {
	const s = new Scene();
	const failed = await s.rows(true);
	const rows = await s.rows(false);
	const node = await s.node();
	const copy = await s.copy();
	const bound = await s.bound();
	stop(s.pid, ExitReason.Normal);
	if (failed.ok || failed.error != "refused 3" || !rows.ok || rows.value.length != 1 || !node.ok || !copy.ok || !bound.ok || bound.value.length != 1) throw new Error("result reply");
	console.log("GUARD-OK");
}

await main();
