import { viaTwice } from "../lib/user";
import { corpus802Twice } from "../lib/twice.h";

export function twiceBoth(x: int32): string { return `${viaTwice(x)},${corpus802Twice(x + 1)}`; }
