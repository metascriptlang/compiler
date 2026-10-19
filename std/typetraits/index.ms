/** True when a `T` owns no managed memory (string, array, `Vec`, class, interface, closure) and declares no lifecycle hook, so its bytes can be copied or mapped as they are. Answered while compiling, per instance: `when (isPlainData<T>()) { … }`. */
@builtin("IsPlainData")
export extern function isPlainData<T>(): boolean;

/** True when every slot that stores a `T` holds its own value that can later change in place (a value struct, tuple, `Vec`, fixed array); false when slots may share one `T` (numbers, booleans, enums, strings, references). Answered while compiling, per instance. */
@builtin("NeedsCopy")
export extern function needsCopy<T>(): boolean;

/** True when `T` is an array `E[]`. Answered while compiling, per instance. */
@builtin("IsArray")
export extern function isArray<T>(): boolean;

/** True when `T` is an object in the TypeScript sense, the question `T extends object` asks: a class, an interface, a struct, an array, a tuple or a function; false for numbers, booleans, strings, enums, literals and `null`. Answered while compiling, per instance. */
@builtin("IsObject")
export extern function isObject<T>(): boolean;
