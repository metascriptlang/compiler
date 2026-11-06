let destroyed: int32 = 0;

class Block {
	data: int32[] = [];
}

function onDestroy(this block: Block): void {
	destroyed += 1;
}

function fill(): void {
	const block = new Block();
	for (let i: int32 = 0; i < 256; i++) block.data.push(i);
}

for (let round: int32 = 0; round < 4096; round++) fill();
if (destroyed != 4096) throw new Error(`bare Wasm DRC destroyed ${destroyed} of 4096 blocks`);
