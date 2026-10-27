// A module global is destroyed after the loop drains, so a promise callback or an await resume reads it alive.
// @stdout: end
// @stdout: direct 1
// @stdout: count 7
// @stdout: helper 2
// @stdout: awaited 5
// @stdout: after await 3
// @exit: 0

const out: string[] = [];
let count: int32 = 1;

function viaHelper(): void {
	out.push("helper");
	console.log(`helper ${out.length}`);
}

async function afterAwait(): Promise<void> {
	const v = await Promise.resolve(5);
	console.log(`awaited ${v}`);
	out.push("await");
	console.log(`after await ${out.length}`);
}

const first: Promise<int32> = Promise.resolve(1);
first.then((v: int32): void => {
	out.push("direct");
	console.log(`direct ${out.length}`);
	console.log(`count ${count}`);
	const second: Promise<int32> = Promise.resolve(2);
	second.then((w: int32): void => {
		viaHelper();
		afterAwait();
	});
});
count = 7;
console.log("end");
