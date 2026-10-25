import { Inner } from "./inner";
import { Fd } from "./fd";

export struct Outer { x: Inner; }
export struct Wrap { fd: Fd; }
