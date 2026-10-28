// @stdout: 1,2,3 3|4 1
// @stdout: 1,1,2,2|a|b|c|5,7
// @stdout: 1,3,2,4
const joined = [[1, 2], [3]].flat();
const sparse: number[][] = [[], [4], []];
console.log(`${joined.join(",")} ${joined.length}|${sparse.flat().join(",")} ${[[1]].flat().length}`);
const doubled = [1, 2].flatMap((x: int32): int32[] => [x, x]);
const parts = ["a b", "c"].flatMap((s: string): string[] => s.split(" "));
const shifted = [5, 6].flatMap((x: int32, i: number): number[] => [x + i]);
console.log(`${doubled.join(",")}|${parts.join("|")}|${shifted.join(",")}`);
const pairs = [[1, 2], [3, 4]].flatMap((row: int32[]): int32[] => [row[0], row[1]]);
console.log(`${pairs[0]},${pairs[2]},${pairs[1]},${pairs[3]}`);
