import { Account, key } from "./account";
export type Signer = distinct Account;
export function key(s: Signer): uint64 { return 99; }
export function bothKeys(a: Account, s: Signer): string { return `${key(a)} ${key(s)}`; }
