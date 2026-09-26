export interface Options { title: string; }
export interface Handle { id: int32; }
export function open(o: Options): Handle { console.log(`open ${o.title}`); return { id: 1 as int32 }; }
