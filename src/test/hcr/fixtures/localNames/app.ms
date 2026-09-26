import { fa } from "./a";
import { fb } from "./b";

async function run(): Promise<void> {
	const x = await fa(1);
	const y = await fb(2);
	console.log(x + y);
}

await run();
