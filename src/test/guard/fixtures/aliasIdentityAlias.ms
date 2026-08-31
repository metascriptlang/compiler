import { Thing } from "./aliasIdentityDecl";

export type TA = Thing;

export function viaAlias(t: TA): number { return t.n; }
