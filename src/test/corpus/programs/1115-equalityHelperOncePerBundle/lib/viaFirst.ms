import { First, Box } from "./types";

export function sameFirst(a: First, b: First): boolean { return a == b; }
export function sameBytesFirst(a: uint8[32], b: uint8[32]): boolean { return a == b; }
export function sameBoxFirst(a: Box<int32>, b: Box<int32>): boolean { return a == b; }
export function pairFirst(a: [int32, int32], b: [int32, int32]): string { return `${a == b},${a < b}`; }
