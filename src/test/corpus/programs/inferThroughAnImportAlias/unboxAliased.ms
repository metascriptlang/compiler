import { CdBx as CdBx_a } from "./box";

export type CdUnbox<T> = T extends CdBx_a<infer U> ? U : never;
export type CdIsBx<T> = T extends CdBx_a<int32> ? int32 : never;

export function cdG(a: CdUnbox<CdBx_a<int32>>): int32 {
	return a;
}
