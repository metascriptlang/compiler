import { Second, Box } from "./types";

export function sameSecond(a: Second, b: Second): boolean { return a == b; }
export function sameBytesSecond(a: uint8[32], b: uint8[32]): boolean { return a == b; }
export function sameBoxSecond(a: Box<int32>, b: Box<int32>): boolean { return a == b; }
export function pairSecond(a: [int32, int32], b: [int32, int32]): string { return `${a == b},${a < b}`; }
