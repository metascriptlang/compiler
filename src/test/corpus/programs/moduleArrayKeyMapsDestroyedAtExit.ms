// @stdout: text 150 149 149 true grid 150 149 149 true
// note: module-level maps keyed by arrays, beside module arrays that still hold their keys at exit; one key
// is dropped mid-run, so the SAN ledger counts a destroy for each key type and checks the rest at exit.
// arrayKeyIdentity holds the int32[] case.

const byText = new Map<string[], int32>();
const texts: string[][] = [];
for (let i = 0; i < 150; i++) {
	const k: string[] = ["t" + i.toString()];
	texts.push(k);
	byText.set(k, i);
}

const byGrid = new Map<int32[][], int32>();
const grids: int32[][][] = [];
for (let i = 0; i < 150; i++) {
	const k: int32[][] = [[i], [i + 1]];
	grids.push(k);
	byGrid.set(k, i);
}

let textFound = 0;
let gridFound = 0;
for (let i = 0; i < 150; i++) {
	if ((byText.get(texts[i]) ?? -1) == i) textFound++;
	if ((byGrid.get(grids[i]) ?? -1) == i) gridFound++;
}
byText.delete(texts[149]);
texts.pop();
byGrid.delete(grids[149]);
grids.pop();
console.log(`text ${textFound} ${byText.size} ${texts.length} ${byText.has(texts[7])} grid ${gridFound} ${byGrid.size} ${grids.length} ${byGrid.has(grids[7])}`);
