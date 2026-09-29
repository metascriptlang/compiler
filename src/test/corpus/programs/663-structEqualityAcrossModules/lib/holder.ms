import { Inner } from "./inner";

export struct Box<T> { v: T; n: int32; }
export struct Holder { b: Box<Inner>; }
