export type Id = distinct int32;
export interface Slot<T> { item: T; }
export function makeId(): Id { return 3 as Id; }
export function makeSlot(): Slot<Id> { return { item: 4 as Id }; }
export function show(i: Id): string { return (i as int32).toString(); }
