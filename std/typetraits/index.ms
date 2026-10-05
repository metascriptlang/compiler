/** True when a `T` owns no managed memory (string, array, `Vec`, class, interface, closure) and declares no lifecycle hook, so its bytes can be copied or mapped as they are. Answered while compiling, per instance: `when (isPlainData<T>()) { … }`. */
@builtin("IsPlainData")
export extern function isPlainData<T>(): boolean;

/** True when every slot that stores a `T` holds its own value that can later change in place (a value struct, tuple, `Vec`, fixed array); false when slots may share one `T` (numbers, booleans, enums, strings, references). Answered while compiling, per instance. */
@builtin("NeedsCopy")
export extern function needsCopy<T>(): boolean;
