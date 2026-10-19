export type Id = distinct float64;
export interface Slot<T> { item: T; }
export function makeId(): Id { return 2.5 as Id; }
export function makeSlot(): Slot<Id> { return { item: 6.5 as Id }; }
export function show(i: Id): string { return (i as float64).toString(); }
