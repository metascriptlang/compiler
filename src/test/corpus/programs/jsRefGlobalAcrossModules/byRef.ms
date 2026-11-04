import { pool, total, pools, Pool, addTo } from "./pool";

function bumpTen(ref p: Pool): void { p.count += 10; }

export function bumpInImporter(): void {
	bumpTen(pool);
	addTo(total, 10);
	bumpTen(pools[0]);
}
