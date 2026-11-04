export enum MemKind { Block, I8, I16, I32, I64, U8, U16, U32, U64, F32, F64, Ptr }

export const CELL_HEADER_SIZE: int32 = 24;

export interface VmSlot {
	name: string;
	offset: int32;
	kind: MemKind;
}

export interface VmLayout {
	size: int32;
	align: int32;
	kind: MemKind;
	header: int32;
	slots: VmSlot[];
}
