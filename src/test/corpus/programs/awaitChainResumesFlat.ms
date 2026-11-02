// @stdout: 100001
// note: each link awaits the previous one, so the 100000 resumptions run one after another from the event loop; a completion that resumed its awaiter inline would nest 100000 deep and overflow a default stack (card 2026-11-01-an-await-chain-10000-deep-overflows-the-stack-in-a-default-build).

async function link(prev: Promise<int32>): Promise<int32> {
	return (await prev) + 1;
}

let p: Promise<int32> = Promise.resolve(1 as int32);
for (let i = 0; i < 100000; i++) p = link(p);
console.log(`${await p}`);
