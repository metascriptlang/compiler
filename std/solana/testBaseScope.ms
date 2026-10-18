import { Signer, Writable } from "./typed";
import { Account } from "./core";
import { address } from "./macro";
import { Pubkey } from "./pubkey";

export struct FarBase { owner: Signer; }
export struct FarDerived extends FarBase { refund: Writable; }

export struct FarKept { owner: Pubkey; }

export struct FarPinned { @address(Pubkey.zero()) system: Account; }
export struct FarPinnedChild extends FarPinned { refund: Writable; }
