// @stdout: b 2|4|9|a|6|7
interface Holder { rows: [string, int32][]; }
function first(ps: [string, int32][]): [string, int32][] { return ps; }
function nested(ps: [string, [int32, int32]][]): int32 { return ps[0][1][1]; }
function vec(v: Array<[string, int32][]>): int32 { return v[0][0][1]; }
const pairs: [string, int32][] = [["a", 1], ["b", 2]];
const grid: [int32, int32][][] = [[[1, 2]], [[3, 4]]];
const h: Holder = { rows: [["z", 9]] };
const out: string[] = [];
out.push(pairs[1][0] + " " + pairs[1][1]);
out.push("" + grid[1][0][1]);
out.push("" + h.rows[0][1]);
out.push(first(pairs)[0][0]);
out.push("" + nested([["q", [5, 6]]]));
out.push("" + vec([[["v", 7]]]));
console.log(out.join("|"));
