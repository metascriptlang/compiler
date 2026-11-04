import { pool } from "./pool";

export function writeFields(): void {
	pool.count = pool.count + 100;
	pool.slots.push(7);
}
