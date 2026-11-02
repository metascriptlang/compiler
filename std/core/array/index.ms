@include("runtime/core/array.h");
@compile("runtime/core/array.c");

export { Array, push, pop, shift, at, indexOf, includes, slice, concat, reverse, sort, fill, count, join, map, setLength, capacity, splice, asString } from "./kernel";
export { sortBy } from "./sortBy";
