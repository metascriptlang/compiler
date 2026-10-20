export struct First { value: int32; }
export struct Second { value: int32; }

export function create(this typeof First): First { return { value: 7 }; }
export function create(this typeof Second): Second { return { value: 9 }; }
