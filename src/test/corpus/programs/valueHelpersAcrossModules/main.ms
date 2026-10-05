// Parity program — two modules of one JS bundle that copy, assign and key the
// same value types share the generated helpers instead of declaring each one
// twice in the bundle's single scope: a struct, a struct holding structs, a
// tuple and a struct-keyed Set.
//
// @stdout: 3,7 9 3 2 2 9-4 9a
// @exit: 0

import { Row, Pair, makeRows, distinctRows, spanOf, pairOf } from "./rows";

const rows = makeRows();
const sums: string[] = [];
for (const row of rows) sums.push(`${row.first + row.last}`);
rows[0] = rows[1];
rows[0].first = 9;
const seen = new Set<Row>();
for (const r of rows) seen.add(r);
const span = spanOf(rows);
const kept = span;
const pairs: Pair[] = [pairOf(rows)];
const pair = pairs[0];
console.log(`${sums.join(",")} ${rows[0].first} ${rows[1].first} ${seen.size} ${distinctRows(rows)} ${kept.from.first}-${kept.to.last} ${pair[0]}${pair[1]}`);
