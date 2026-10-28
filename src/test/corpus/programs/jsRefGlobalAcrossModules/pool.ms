export struct Pool {
	slots: Vec<int32>;
	count: int32;
}

export let pool: Pool = { slots: [0], count: 0 };

function bump(ref p: Pool): void { p.count += 1; }

export function bumpInOwner(): void { bump(pool); }
