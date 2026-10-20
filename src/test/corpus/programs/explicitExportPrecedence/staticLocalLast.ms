export * from "./freeCreate";
export struct Local { value: int32; }
export function create(this typeof Local): Local { return { value: 11 }; }
