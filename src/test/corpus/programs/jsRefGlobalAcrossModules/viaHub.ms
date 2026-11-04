import { pool, total, bump, addTo } from "./hub";

export function readViaHub(): int32 { return pool.count + pool.slots.length + total; }

export function bumpViaHub(): void {
	bump(pool);
	addTo(total, 1000);
	pool.count = pool.count + 1000;
}
