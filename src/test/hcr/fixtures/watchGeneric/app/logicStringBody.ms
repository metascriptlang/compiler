import { Cell } from "../lib/cell";

export function run(): int32 {
	const name = new Cell<string>("seven").get();
	return (new Cell<int32>(6).get() + name.length) as int32;
}
