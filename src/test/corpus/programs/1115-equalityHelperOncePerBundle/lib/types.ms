export struct Leaf { bits: uint64; }
export struct First { leaf: Leaf; bytes: uint8[32]; }
export struct Second { leaf: Leaf; bytes: uint8[32]; }
export struct Box<T> { v: T; }
