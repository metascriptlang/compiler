pub mod error;
pub mod instructions;
pub mod state;
use anchor_lang::prelude::*;
pub use instructions::*;
declare_id!("55555555555555555555555555555555555555555555");
pub const UPDATE_AUTHORITY: Address = Address::new_from_array([
    234, 74, 108, 99, 226, 156, 82, 10, 190, 245, 80, 123, 19, 46, 197, 249, 149, 71, 118, 174,
    190, 190, 123, 146, 66, 30, 234, 105, 20, 70, 210, 44,
]);
#[program]
pub mod prop_amm_v2 {
    use super::*;
    #[discrim = 0]
    #[inline(always)]
    pub fn update(ctx: &mut Context<Update>, new_price: u64) -> Result<()> {
        if ctx.accounts.oracle.account().data_len() != 48 {
            return Err(ProgramError::Custom(102));
        }
        if ctx.accounts.authority.address() != &UPDATE_AUTHORITY {
            return Err(ProgramError::Custom(105));
        }
        ctx.accounts.oracle.price = new_price;
        Ok(())
    }
    #[discrim = 1]
    #[inline(always)]
    pub fn initialize(ctx: &mut Context<Initialize>) -> Result<()> {
        ctx.accounts.oracle.authority = *ctx.accounts.payer.address();
        ctx.accounts.oracle.price = 0;
        Ok(())
    }
    #[discrim = 2]
    #[inline(always)]
    pub fn rotate_authority(ctx: &mut Context<RotateAuthority>, new_authority: [u8; 32]) -> Result<()> {
        ctx.accounts.oracle.authority = Address::new_from_array(new_authority);
        Ok(())
    }
}
#[derive(Accounts)]
pub struct Update {
    #[account(mut)]
    pub oracle: Account<state::Oracle>,
    pub authority: Signer,
}
