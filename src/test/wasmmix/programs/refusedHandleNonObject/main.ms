// @error: Type 'int32' does not satisfy constraint 'object' for type parameter 'T' in 'retain'
// @error: Type 'boolean' does not satisfy constraint 'object' for type parameter 'T' in 'Handle'
// @error: Type 'int64' does not satisfy constraint 'object' for type parameter 'T' in 'retain'
// note: Handle<T> counts a heap object, so T is bound to object as the reference's GC_ref takes only a ref; a number once compiled on C and panicked in msFfiRetain.
import { Handle } from "std/ffi";

function park<U>(u: U): void { Handle.retain(u); }

const h = Handle.retain(1 as int32);
let flag: Handle<boolean> | null = null;
park(2 as int64);
console.log("unreachable");
