import { Node } from "std/meta";

export function signer(value: Node, context: Node): Node { return value; }
export function writable(value: Node, context: Node): Node { return value; }
export function seeds(first: string, second: string): void {}
export function bump(value: int32): void {}
export function address(value: int32): void {}
export function label(text: string): void {}
