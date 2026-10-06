import { signer, writable, seeds, bump, address, label } from "./decorators";

export struct Pubkey { bytes: int32; }
export function systemProgram(this typeof Pubkey): Pubkey { return { bytes: 0 }; }

export struct Accounts {
	@signer @writable maker: int32;
	@seeds("config", mint) @bump(config.bump) config: int32;
	@address(Pubkey.systemProgram()) vault: int32;
	tail: int32;
}

export struct Plain {
	maker: int32;
	config: int32;
	vault: int32;
	tail: int32;
}

export interface Note {
	@label("x") note: string;
	plain: string;
}

export struct Pair<T> {
	@signer first: T;
	second: T;
}
