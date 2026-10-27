import { pool, Pool } from "./pool";

function bumpTen(ref p: Pool): void { p.count += 10; }

export function bumpInImporter(): void { bumpTen(pool); }
