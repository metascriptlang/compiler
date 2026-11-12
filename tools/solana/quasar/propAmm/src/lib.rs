#![no_std]
use quasar_lang::prelude::*;

declare_id!("55555555555555555555555555555555555555555555");

pub const UPDATE_AUTHORITY: Address = Address::new_from_array([
    234, 74, 108, 99, 226, 156, 82, 10, 190, 245, 80, 123, 19, 46, 197, 249, 149, 71, 118, 174,
    190, 190, 123, 146, 66, 30, 234, 105, 20, 70, 210, 44,
]);

#[program]
mod prop_amm_quasar {
    use super::*;

    #[instruction(discriminator = [0xdb, 0xc8, 0x58, 0xb0, 0x9e, 0x3f, 0xfd, 0x7f])]
    pub fn update(ctx: Ctx<Update>, new_price: u64) -> Result<(), ProgramError> {
        if ctx.accounts.oracle.to_account_view().data_len() != 48 {
            return Err(ProgramError::Custom(102));
        }
        if !quasar_lang::keys_eq(ctx.accounts.authority.address(), &UPDATE_AUTHORITY) {
            return Err(ProgramError::Custom(105));
        }
        ctx.accounts.oracle.price = new_price.into();
        Ok(())
    }

    #[instruction(discriminator = [0xaf, 0xaf, 0x6d, 0x1f, 0x0d, 0x98, 0x9b, 0xed])]
    pub fn initialize(ctx: Ctx<Initialize>) -> Result<(), ProgramError> {
        let a = &mut ctx.accounts;
        a.oracle.authority = *a.payer.address();
        a.oracle.price = 0u64.into();
        Ok(())
    }

    #[instruction(discriminator = [0xf8, 0xe1, 0x97, 0x23, 0x1c, 0x0f, 0x55, 0x0c])]
    pub fn rotate_authority(ctx: Ctx<RotateAuthority>, new_authority: [u8; 32]) -> Result<(), ProgramError> {
        ctx.accounts.oracle.authority = Address::new_from_array(new_authority);
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Update {
    #[account(mut)]
    pub oracle: Account<Oracle>,
    pub authority: Signer,
}

#[derive(Accounts)]
pub struct Initialize {
    #[account(mut)]
    pub payer: Signer,
    #[account(init, payer = payer)]
    pub oracle: Account<Oracle>,
    pub system_program: Program<SystemProgram>,
}

#[derive(Accounts)]
pub struct RotateAuthority {
    #[account(mut, has_one(authority))]
    pub oracle: Account<Oracle>,
    pub authority: Signer,
}

#[account(discriminator = [0x8b, 0xc2, 0x83, 0xb3, 0x8c, 0xb3, 0xe5, 0xf4])]
pub struct Oracle {
    pub authority: Address,
    pub price: u64,
}
