// @skip-js: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: removed 2 5 | kept 1 3 4 6 | replaced 4 | now 1 3 9 6 7 | reversed 7 6 9 3 1 | all 8
// note: splice and reverse move the elements they keep; only an element splice takes out is released, and at that call.
class Item { id: int32 = 0; }

let gone = "";
let released: int32 = 0;
function onDestroy(this it: Item): void {
	gone = gone + " " + it.id.toString();
	released += 1;
}

function item(id: int32): Item {
	const it = new Item();
	it.id = id;
	return it;
}

function ids(xs: Item[]): string {
	let out = "";
	for (const x of xs) out = out + (out == "" ? "" : " ") + x.id.toString();
	return out;
}

let line = "";
{
	const xs: Item[] = [item(1), item(2), item(3), item(4), item(5), item(6)];
	xs.splice(1, 1);
	xs.splice(-2, 1);
	line = `removed${gone} | kept ${ids(xs)}`;
	gone = "";
	xs.splice(2, 1, item(9));
	line = line + ` | replaced${gone}`;
	xs.splice(10, 0, item(7));
	line = line + ` | now ${ids(xs)}`;
	xs.reverse();
	line = line + ` | reversed ${ids(xs)}`;
}
console.log(`${line} | all ${released}`);
