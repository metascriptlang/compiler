import { scale, twice } from "./include/lib/quoted.h";

export function scaled(): int32 { return scale(twice(2), 5); }
