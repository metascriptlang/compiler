import { Cell } from "../lib/cell";

export function run(): int32 {
	return new Cell<int32>(6).get();
}
