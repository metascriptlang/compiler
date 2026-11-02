import { helper } from "./call";

export enum Need { Value, Items }

function privateTag(): string { return "t"; }

export function readIt(n: int32, need: Need = Need.Value): string { return need == Need.Value ? `v${n}` : `i${n}`; }

export function tagged(n: int32, tag: string = privateTag()): string { return `${tag}${n}`; }

export class Box {
	need: Need;
	constructor(need: Need = Need.Items) { this.need = need; }
}

export function viaCall(n: int32): string { return helper(n); }
