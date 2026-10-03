import { make } from "./account";
export * from "./account";
export * from "./signer";
export * from "./meta";
export * from "./mutable";
export function twice(): int32 { return make() * 2; }
