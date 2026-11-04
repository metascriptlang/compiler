export struct Pool {
	slots: Vec<int32>;
	count: int32;
}

export let pool: Pool = { slots: [0], count: 0 };
export let total: int32 = 0;
export let pools: Vec<Pool> = [{ slots: [], count: 0 }];

export function bump(ref p: Pool): void { p.count += 1; }
export function addTo(ref n: int32, by: int32): void { n += by; }

export function bumpInOwner(): void {
	bump(pool);
	addTo(total, 1);
	bump(pools[0]);
}
