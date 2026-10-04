export struct Pet {
	burrow: uint64; harvest: uint64; xp: uint64; slot: uint64;
	a0: uint64; a1: uint64; a2: uint64; a3: uint64; a4: uint64; a5: uint64; a6: uint64; a7: uint64;
	b0: uint64; b1: uint64; b2: uint64; b3: uint64; b4: uint64; b5: uint64; b6: uint64; b7: uint64;
	c0: uint64; c1: uint64; c2: uint64; c3: uint64; c4: uint64; c5: uint64; c6: uint64; c7: uint64;
	d0: uint64; d1: uint64; d2: uint64; d3: uint64; d4: uint64; d5: uint64; d6: uint64; d7: uint64;
	e0: uint64; e1: uint64; e2: uint64; e3: uint64; e4: uint64; e5: uint64; e6: uint64; e7: uint64;
	f0: uint64; f1: uint64; f2: uint64; f3: uint64; f4: uint64; f5: uint64; f6: uint64; f7: uint64;
	hearts: uint8; alive: boolean;
}
export struct Record { epoch: uint64; seed: uint64; stake: uint64; loot: uint64; r0: uint64; r1: uint64; r2: uint64; r3: uint64; r4: uint64; r5: uint64; r6: uint64; r7: uint64; }
export struct Settlement { attacker: Pet; defender: Pet; record: Record; }
export enum AttackError { TooPoor }

export function gain(p: Pet, n: uint64): Pet { return { ...p, xp: p.xp + n }; }
export function weigh(p: Pet): uint64 { return p.burrow + p.harvest + p.c7; }

