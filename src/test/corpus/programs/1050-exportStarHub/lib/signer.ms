import { Account } from "./account";
export type Signer = distinct Account;
export function key(this s: Signer): uint64 { return (s as Account).address * 3; }
