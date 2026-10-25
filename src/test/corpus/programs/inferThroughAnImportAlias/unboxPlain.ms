import { CdBx } from "./box";

export type CdUnbox<T> = T extends CdBx<infer U> ? U : never;
