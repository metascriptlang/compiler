#![no_std]

use {
    core::mem::size_of,
    pinocchio::{
        account::{AccountView, RefMut},
        address::{address_eq, Address},
        error::ProgramError,
        no_allocator, nostd_panic_handler, ProgramResult,
    },
    pinocchio_system::instructions::CreateAccountAllowPrefund,
};

const INSTRUCTION_MISSING: u32 = 100;
const INSTRUCTION_FALLBACK_NOT_FOUND: u32 = 101;
const INSTRUCTION_DID_NOT_DESERIALIZE: u32 = 102;
const UPDATE_AUTHORITY_MISMATCH: u32 = 105;
const CONSTRAINT_MUT: u32 = 2000;
const CONSTRAINT_DUPLICATE_MUTABLE_ACCOUNT: u32 = 2040;
const ACCOUNT_DISCRIMINATOR_NOT_FOUND: u32 = 3001;
const ACCOUNT_DISCRIMINATOR_MISMATCH: u32 = 3002;
const ACCOUNT_DID_NOT_DESERIALIZE: u32 = 3003;
const ACCOUNT_NOT_ENOUGH_KEYS: u32 = 3005;
const ACCOUNT_OWNED_BY_WRONG_PROGRAM: u32 = 3007;
const INVALID_PROGRAM_ID: u32 = 3008;
const INVALID_PROGRAM_EXECUTABLE: u32 = 3009;
const ACCOUNT_NOT_SIGNER: u32 = 3010;
const TRYING_TO_INIT_PAYER_AS_PROGRAM_ACCOUNT: u32 = 4101;
const ORACLE_AUTHORITY_MISMATCH: u32 = 6000;

const UPDATE: u64 = u64::from_le_bytes([219, 200, 88, 176, 158, 63, 253, 127]);
const INITIALIZE: u64 = u64::from_le_bytes([175, 175, 109, 31, 13, 152, 155, 237]);
const ROTATE_AUTHORITY: u64 = u64::from_le_bytes([248, 225, 151, 35, 28, 15, 85, 12]);
const ORACLE_DISCRIMINATOR: u64 = u64::from_le_bytes([139, 194, 131, 179, 140, 179, 229, 244]);

const UPDATE_AUTHORITY: Address = Address::new_from_array([
    234, 74, 108, 99, 226, 156, 82, 10, 190, 245, 80, 123, 19, 46, 197, 249, 149, 71, 118, 174,
    190, 190, 123, 146, 66, 30, 234, 105, 20, 70, 210, 44,
]);

#[repr(C)]
struct Oracle {
    discriminator: u64,
    authority: Address,
    price: u64,
}

const ORACLE_SPACE: usize = size_of::<Oracle>();

no_allocator!();
nostd_panic_handler!();

trait Slots {
    fn count(&self) -> usize;
    unsafe fn view(&self, slot: usize) -> AccountView;
    unsafe fn named_by_another_slot(&self, slot: usize, declared: usize) -> bool;
}

#[cfg(not(feature = "lazy"))]
mod eager {
    use super::*;

    pinocchio::program_entrypoint!(process_instruction);

    struct Parsed<'a>(&'a [AccountView]);

    impl Slots for Parsed<'_> {
        #[inline(always)]
        fn count(&self) -> usize {
            self.0.len()
        }

        #[inline(always)]
        unsafe fn view(&self, slot: usize) -> AccountView {
            *self.0.get_unchecked(slot)
        }

        #[inline(always)]
        unsafe fn named_by_another_slot(&self, slot: usize, declared: usize) -> bool {
            let named = self.0.get_unchecked(slot).account_ptr();
            let mut other = 0;
            while other < declared {
                if other != slot && self.0.get_unchecked(other).account_ptr() == named {
                    return true;
                }
                other += 1;
            }
            while other < self.0.len() {
                if self.0.get_unchecked(other).account_ptr() == named {
                    return true;
                }
                other += 1;
            }
            false
        }
    }

    fn process_instruction(
        program_id: &Address,
        accounts: &mut [AccountView],
        data: &[u8],
    ) -> ProgramResult {
        dispatch(program_id, &Parsed(accounts), data)
    }
}

#[cfg(feature = "lazy")]
mod lazy {
    use {
        super::*,
        core::mem::MaybeUninit,
        pinocchio::entrypoint::lazy::{InstructionContext, MaybeAccount},
    };

    pinocchio::lazy_program_entrypoint!(process_instruction);

    const DECLARED_SLOTS: usize = 3;

    struct Walked {
        views: [MaybeUninit<AccountView>; DECLARED_SLOTS],
        count: usize,
        named_twice: usize,
    }

    impl Slots for Walked {
        #[inline(always)]
        fn count(&self) -> usize {
            self.count
        }

        #[inline(always)]
        unsafe fn view(&self, slot: usize) -> AccountView {
            self.views.get_unchecked(slot).assume_init()
        }

        #[inline(always)]
        unsafe fn named_by_another_slot(&self, slot: usize, _declared: usize) -> bool {
            self.named_twice & (1 << slot) != 0
        }
    }

    #[inline(always)]
    fn process_instruction(mut context: InstructionContext) -> ProgramResult {
        let mut walked = Walked {
            views: [const { MaybeUninit::uninit() }; DECLARED_SLOTS],
            count: context.remaining() as usize,
            named_twice: 0,
        };
        let mut slot = 0;
        while slot < walked.count {
            match unsafe { context.next_account_unchecked() } {
                MaybeAccount::Account(view) => {
                    if slot < DECLARED_SLOTS {
                        walked.views[slot].write(view);
                    }
                }
                MaybeAccount::Duplicated(original) => {
                    let original = original as usize;
                    if original < DECLARED_SLOTS {
                        walked.named_twice |= 1 << original;
                        if slot < DECLARED_SLOTS {
                            walked.named_twice |= 1 << slot;
                            walked.views[slot] = walked.views[original];
                        }
                    }
                }
            }
            slot += 1;
        }
        let data = unsafe { context.instruction_data_unchecked() };
        let program_id = unsafe { context.program_id_unchecked() };
        dispatch(program_id, &walked, data)
    }
}

#[inline(always)]
fn dispatch<S: Slots>(program_id: &Address, slots: &S, data: &[u8]) -> ProgramResult {
    if data.len() < 8 {
        return Err(ProgramError::Custom(INSTRUCTION_MISSING));
    }
    let tag = unsafe { (data.as_ptr() as *const u64).read_unaligned() };
    let args = unsafe { data.get_unchecked(8..) };
    if tag == UPDATE {
        return update(program_id, slots, args);
    }
    if tag == INITIALIZE {
        return initialize(program_id, slots);
    }
    if tag == ROTATE_AUTHORITY {
        return rotate_authority(program_id, slots, args);
    }
    Err(ProgramError::Custom(INSTRUCTION_FALLBACK_NOT_FOUND))
}

#[cold]
#[inline(never)]
fn short_oracle(oracle: &AccountView, length: usize) -> ProgramError {
    if length < 8 {
        return ProgramError::Custom(ACCOUNT_DISCRIMINATOR_NOT_FOUND);
    }
    if unsafe { (oracle.data_ptr() as *const u64).read() } != ORACLE_DISCRIMINATOR {
        return ProgramError::Custom(ACCOUNT_DISCRIMINATOR_MISMATCH);
    }
    ProgramError::Custom(ACCOUNT_DID_NOT_DESERIALIZE)
}

#[inline(always)]
fn mutable_oracle<'a, S: Slots>(
    program_id: &Address,
    slots: &S,
    slot: usize,
    declared: usize,
    oracle: &'a mut AccountView,
) -> Result<RefMut<'a, Oracle>, ProgramError> {
    if !address_eq(oracle.owner(), program_id) {
        return Err(ProgramError::Custom(ACCOUNT_OWNED_BY_WRONG_PROGRAM));
    }
    let length = oracle.data_len();
    if length < ORACLE_SPACE {
        return Err(short_oracle(oracle, length));
    }
    if unsafe { (oracle.data_ptr() as *const u64).read() } != ORACLE_DISCRIMINATOR {
        return Err(ProgramError::Custom(ACCOUNT_DISCRIMINATOR_MISMATCH));
    }
    if !oracle.is_writable() {
        return Err(ProgramError::Custom(CONSTRAINT_MUT));
    }
    if unsafe { slots.named_by_another_slot(slot, declared) } {
        return Err(ProgramError::Custom(CONSTRAINT_DUPLICATE_MUTABLE_ACCOUNT));
    }
    let data = oracle.try_borrow_mut()?;
    Ok(RefMut::map(data, |bytes| unsafe {
        &mut *(bytes.as_mut_ptr() as *mut Oracle)
    }))
}

#[inline(always)]
fn writable_signer<S: Slots>(
    slots: &S,
    slot: usize,
    declared: usize,
    account: &AccountView,
) -> ProgramResult {
    if !account.is_signer() {
        return Err(ProgramError::Custom(ACCOUNT_NOT_SIGNER));
    }
    if unsafe { slots.named_by_another_slot(slot, declared) } {
        return Err(ProgramError::Custom(CONSTRAINT_DUPLICATE_MUTABLE_ACCOUNT));
    }
    if !account.is_writable() {
        return Err(ProgramError::Custom(CONSTRAINT_MUT));
    }
    Ok(())
}

#[inline(always)]
fn update<S: Slots>(program_id: &Address, slots: &S, args: &[u8]) -> ProgramResult {
    if args.len() < 8 {
        return Err(ProgramError::Custom(INSTRUCTION_DID_NOT_DESERIALIZE));
    }
    let new_price = unsafe { (args.as_ptr() as *const u64).read_unaligned() };
    if slots.count() < 2 {
        return Err(ProgramError::Custom(ACCOUNT_NOT_ENOUGH_KEYS));
    }
    let (mut oracle, authority) = unsafe { (slots.view(0), slots.view(1)) };
    let mut state = mutable_oracle(program_id, slots, 0, 2, &mut oracle)?;
    if !authority.is_signer() {
        return Err(ProgramError::Custom(ACCOUNT_NOT_SIGNER));
    }
    if !address_eq(authority.address(), &UPDATE_AUTHORITY) {
        return Err(ProgramError::Custom(UPDATE_AUTHORITY_MISMATCH));
    }
    state.price = new_price;
    Ok(())
}

#[inline(always)]
fn initialize<S: Slots>(program_id: &Address, slots: &S) -> ProgramResult {
    if slots.count() < 3 {
        return Err(ProgramError::Custom(ACCOUNT_NOT_ENOUGH_KEYS));
    }
    let (payer, mut oracle, system_program) =
        unsafe { (slots.view(0), slots.view(1), slots.view(2)) };
    writable_signer(slots, 0, 3, &payer)?;
    writable_signer(slots, 1, 3, &oracle)?;
    if !address_eq(system_program.address(), &pinocchio_system::ID) {
        return Err(ProgramError::Custom(INVALID_PROGRAM_ID));
    }
    if !system_program.executable() {
        return Err(ProgramError::Custom(INVALID_PROGRAM_EXECUTABLE));
    }
    if address_eq(payer.address(), oracle.address()) {
        return Err(ProgramError::Custom(TRYING_TO_INIT_PAYER_AS_PROGRAM_ACCOUNT));
    }
    CreateAccountAllowPrefund::with_minimum_balance(
        &payer,
        &oracle,
        ORACLE_SPACE as u64,
        program_id,
        None,
    )?
    .invoke()?;
    let mut data = oracle.try_borrow_mut()?;
    let state = unsafe { &mut *(data.as_mut_ptr() as *mut Oracle) };
    state.discriminator = ORACLE_DISCRIMINATOR;
    state.authority = *payer.address();
    state.price = 0;
    Ok(())
}

#[inline(always)]
fn rotate_authority<S: Slots>(program_id: &Address, slots: &S, args: &[u8]) -> ProgramResult {
    if args.len() < 32 {
        return Err(ProgramError::Custom(INSTRUCTION_DID_NOT_DESERIALIZE));
    }
    let new_authority = unsafe { &*(args.as_ptr() as *const Address) };
    if slots.count() < 2 {
        return Err(ProgramError::Custom(ACCOUNT_NOT_ENOUGH_KEYS));
    }
    let (mut oracle, authority) = unsafe { (slots.view(0), slots.view(1)) };
    let mut state = mutable_oracle(program_id, slots, 0, 2, &mut oracle)?;
    if !authority.is_signer() {
        return Err(ProgramError::Custom(ACCOUNT_NOT_SIGNER));
    }
    if !address_eq(&state.authority, authority.address()) {
        return Err(ProgramError::Custom(ORACLE_AUTHORITY_MISMATCH));
    }
    state.authority = *new_authority;
    Ok(())
}
