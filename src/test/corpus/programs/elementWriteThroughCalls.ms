// @stdout: 10 10,25,31 9z
// note: an element write whose array and index are both calls evaluates each once and still checks the bound. JS takes the array into a temporary, as Nim's jsgen maybeMakeTemp does, where it used to refuse the write; C evaluates the place once in the analyzer. Covers =, +=, ++, a value-struct element (copied in, not aliased) and a write inside an arrow's block body.

struct Cell { n: int32; tag: string; }

class Shelf {
	nums: int32[] = [10, 20, 30];
	cells: Cell[] = [{ n: 1, tag: "a" }, { n: 2, tag: "b" }];
}

let calls: int32 = 0;
function at(i: int32): int32 { calls += 1; return i; }
function shelf(s: Shelf[]): Shelf { calls += 1; return s[0]; }

const shelves: Shelf[] = [new Shelf()];
shelf(shelves).nums[at(0)] = 11;
shelf(shelves).nums[at(1)] += 5;
shelf(shelves).nums[at(2)]++;
let fresh: Cell = { n: 9, tag: "z" };
shelf(shelves).cells[at(1)] = fresh;
fresh.n = 99;
const bump = (k: int32): void => {
	shelf(shelves).nums[at(k)] -= 1;
};
bump(0);
console.log(`${calls} ${shelves[0].nums[0]},${shelves[0].nums[1]},${shelves[0].nums[2]} ${shelves[0].cells[1].n}${shelves[0].cells[1].tag}`);
