import { Link } from "./types";

export function link(): Link<int32> { return { value: 2, next: null }; }
export function different(): Link<string> { return { value: "x", next: null }; }
