// note: An awaited unsigned result keeps its value inside an async function, at every width up to 32 bits.
// @stdout: u8 200
// @stdout: u16 60000
// @stdout: u32 4000000000

async function byte(): Promise<uint8> { return 200 as uint8; }
async function half(): Promise<uint16> { return 60000 as uint16; }
async function word(): Promise<uint32> { return 4000000000 as uint32; }

async function run(): Promise<void> {
	const a = await byte();
	console.log(`u8 ${a}`);
	const b = await half();
	console.log(`u16 ${b}`);
	const c = await word();
	console.log(`u32 ${c}`);
}

run();
