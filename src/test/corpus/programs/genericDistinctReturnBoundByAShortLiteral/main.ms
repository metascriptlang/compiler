// @stdout: true st 10 20 10
// note: an arrow with fewer parameters than its slot binds the type parameter of a generic in
// another module that returns a distinct accessor, one `Cell<T>` per call. The checker used to
// bind `T` to its inference placeholder, which left `Cell` uninstantiated: C refused it at
// codegen, JS read an undefined class and `--split` exported a `Cell` nothing declares.
import { make, memo } from "./lib";

let calls: int32 = 0;
const flag = make((): boolean => true);
const word = make(() => "st");
const first = memo((): int32 => { calls += 1; return calls * 10; });
const second = memo((): int32 => { calls += 1; return calls * 10; });
console.log(`${flag()} ${word()} ${first()} ${second()} ${first()}`);
