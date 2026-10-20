import { Root, Named } from "./root";

export struct Base extends Root { x: int32; }
export struct Derived extends Base { y: int32; }
export interface Tagged extends Named { tag: int32; }
export interface Sized { size: int32; }
export interface Both extends Tagged, Sized { n: int32; }
export struct Box<T> { v: T; }
export struct IntBox extends Box<int32> { w: int32; }
