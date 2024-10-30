module suilend::lending_market {
    // === Imports ===
    use sui::object::{Self, ID, UID};
    use suilend::rate_limiter::{Self, RateLimiter, RateLimiterConfig};
    use std::ascii::{Self};
    use sui::event::{Self};
    use suilend::decimal::{Self, Decimal, mul, ceil, div, add, floor, gt, min, saturating_floor};
    use sui::object_table::{Self, ObjectTable};
    use sui::bag::{Self, Bag};
    use sui::clock::{Self, Clock};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use suilend::reserve::{Self, Reserve, CToken};
    use suilend::reserve_config::{ReserveConfig, borrow_fee};
    use suilend::obligation::{Self, Obligation};
    use sui::coin::{Self, Coin, CoinMetadata};
    use sui::balance::{Self};
    use pyth::price_info::{PriceInfoObject};
    use std::type_name::{Self, TypeName};
    use std::vector::{Self};
    use std::option::{Self, Option};
    use suilend::liquidity_mining::{Self};
    use sui::package;

    // === Errors ===
    const EIncorrectVersion: u64 = 1;
    const ETooSmall: u64 = 2;
    const EWrongType: u64 = 3; // I don't think these assertions are necessary
    const EDuplicateReserve: u64 = 4;
    const ERewardPeriodNotOver: u64 = 5;
    const ECannotClaimReward: u64 = 6;
    const EInvalidObligationId: u64 = 7;

    // === Constants ===
    const CURRENT_VERSION: u64 = 5;
    const U64_MAX: u64 = 18_446_744_073_709_551_615;

    // === One time Witness ===
    public struct LENDING_MARKET has drop {}

    fun init(otw: LENDING_MARKET, ctx: &mut TxContext) {
        package::claim_and_keep(otw, ctx);
    }

    // === Structs ===
    public struct LendingMarket<phantom P> has key, store {
        id: UID,
        version: u64,

        reserves: vector<Reserve<P>>,
        obligations: ObjectTable<ID, Obligation<P>>,

        // window duration is in seconds
        rate_limiter: RateLimiter,
        fee_receiver: address,

        /// unused
        bad_debt_usd: Decimal,
        /// unused
        bad_debt_limit_usd: Decimal,
    }

    public struct LendingMarketOwnerCap<phantom P> has key, store {
        id: UID,
        lending_market_id: ID
    }

    public struct ObligationOwnerCap<phantom P> has key, store {
        id: UID,
        obligation_id: ID
    }

    // cTokens redemptions and borrows are rate limited to mitigate exploits. however, 
    // on a liquidation we don't want to rate limit redemptions because we don't want liquidators to 
    // get stuck holding cTokens. So the liquidate function issues this exemption 
    // to the liquidator. This object can't' be stored or transferred -- only dropped or consumed 
    // in the same tx block.
    public struct RateLimiterExemption<phantom P, phantom T> has drop {
        amount: u64
    }

    // === Events ===
    public struct MintEvent has drop, copy {
        lending_market_id: address,
        coin_type: TypeName,
        reserve_id: address,
        liquidity_amount: u64,
        ctoken_amount: u64,
    }

    public struct RedeemEvent has drop, copy {
        lending_market_id: address,
        coin_type: TypeName,
        reserve_id: address,
        ctoken_amount: u64,
        liquidity_amount: u64,
    }

    public struct DepositEvent has drop, copy {
        lending_market_id: address,
        coin_type: TypeName,
        reserve_id: address,
        obligation_id: address,
        ctoken_amount: u64,
    }

    public struct WithdrawEvent has drop, copy {
        lending_market_id: address,
        coin_type: TypeName,
        reserve_id: address,
        obligation_id: address,
        ctoken_amount: u64,
    }

    public struct BorrowEvent has drop, copy {
        lending_market_id: address,
        coin_type: TypeName,
        reserve_id: address,
        obligation_id: address,
        liquidity_amount: u64,
        origination_fee_amount: u64,
    }

    public struct RepayEvent has drop, copy {
        lending_market_id: address,
        coin_type: TypeName,
        reserve_id: address,
        obligation_id: address,
        liquidity_amount: u64,
    }

    public struct ForgiveEvent has drop, copy {
        lending_market_id: address,
        coin_type: TypeName,
        reserve_id: address,
        obligation_id: address,
        liquidity_amount: u64,
    }

    public struct LiquidateEvent has drop, copy {
        lending_market_id: address,
        repay_reserve_id: address,
        withdraw_reserve_id: address,
        obligation_id: address,
        repay_coin_type: TypeName,
        withdraw_coin_type: TypeName,
        repay_amount: u64,
        withdraw_amount: u64,
        protocol_fee_amount: u64,
        liquidator_bonus_amount: u64,
    }

    public struct ClaimRewardEvent has drop, copy {
        lending_market_id: address,
        reserve_id: address,
        obligation_id: address,

        is_deposit_reward: bool,
        pool_reward_id: address,
        coin_type: TypeName,
        liquidity_amount: u64,
    }

    // === Public-Mutative Functions ===
    public(package) fun create_lending_market<P>(ctx: &mut TxContext): (
        LendingMarketOwnerCap<P>, 
        LendingMarket<P>
    ) {
        let lending_market = LendingMarket<P> {
            id: object::new(ctx),
            version: CURRENT_VERSION,
            reserves: vector::empty(),
            obligations: object_table::new(ctx),
            rate_limiter: rate_limiter::new(rate_limiter::new_config(1, 18_446_744_073_709_551_615), 0),
            fee_receiver: tx_context::sender(ctx),
            bad_debt_usd: decimal::from(0),
            bad_debt_limit_usd: decimal::from(0),
        };
        
        let owner_cap = LendingMarketOwnerCap<P> { 
            id: object::new(ctx), 
            lending_market_id: object::id(&lending_market) 
        };

        (owner_cap, lending_market)
    }

    /// Cache the price from pyth onto the reserve object. this needs to be done for all
    /// relevant reserves used by an Obligation before any borrow/withdraw/liquidate can be performed.
    public fun refresh_reserve_price<P>(
        lending_market: &mut LendingMarket<P>, 
        reserve_array_index: u64,
        clock: &Clock,
        price_info: &PriceInfoObject,
    ) {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        reserve::update_price<P>(reserve, clock, price_info);
    }

    public fun create_obligation<P>(
        lending_market: &mut LendingMarket<P>, 
        ctx: &mut TxContext
    ): ObligationOwnerCap<P> {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);

        let obligation = obligation::create_obligation<P>(object::id(lending_market),ctx);
        let cap = ObligationOwnerCap<P> { 
            id: object::new(ctx), 
            obligation_id: object::id(&obligation) 
        };

        object_table::add(&mut lending_market.obligations, object::id(&obligation), obligation);

        cap
    }

    public fun deposit_liquidity_and_mint_ctokens<P, T>(
        lending_market: &mut LendingMarket<P>, 
        reserve_array_index: u64,
        clock: &Clock,
        deposit: Coin<T>,
        ctx: &mut TxContext
    ): Coin<CToken<P, T>> {
        let lending_market_id = object::id_address(lending_market);
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        assert!(coin::value(&deposit) > 0, ETooSmall);

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);
        reserve::compound_interest(reserve, clock);

        let deposit_amount = coin::value(&deposit);
        let ctokens = reserve::deposit_liquidity_and_mint_ctokens<P, T>(
            reserve, 
            coin::into_balance(deposit)
        );

        assert!(balance::value(&ctokens) > 0, ETooSmall);

        event::emit(MintEvent {
            lending_market_id,
            coin_type: type_name::get<T>(),
            reserve_id: object::id_address(reserve),
            liquidity_amount: deposit_amount,
            ctoken_amount: balance::value(&ctokens),
        });

        coin::from_balance(ctokens, ctx)
    }

    public fun redeem_ctokens_and_withdraw_liquidity<P, T>(
        lending_market: &mut LendingMarket<P>, 
        reserve_array_index: u64,
        clock: &Clock,
        ctokens: Coin<CToken<P, T>>,
        mut rate_limiter_exemption: Option<RateLimiterExemption<P, T>>,
        ctx: &mut TxContext
    ): Coin<T> {
        let lending_market_id = object::id_address(lending_market);
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        assert!(coin::value(&ctokens) > 0, ETooSmall);

        let ctoken_amount = coin::value(&ctokens);

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);

        reserve::compound_interest(reserve, clock);

        let mut exempt_from_rate_limiter = false;
        if (option::is_some(&rate_limiter_exemption)) {
            let exemption = option::borrow_mut(&mut rate_limiter_exemption);
            if (exemption.amount >= ctoken_amount) {
                exempt_from_rate_limiter = true;
            };
        };

        if (!exempt_from_rate_limiter) {
            rate_limiter::process_qty(
                &mut lending_market.rate_limiter, 
                clock::timestamp_ms(clock) / 1000,
                reserve::ctoken_market_value_upper_bound(reserve, ctoken_amount)
            );
        };

        let liquidity = reserve::redeem_ctokens<P, T>(
            reserve, 
            coin::into_balance(ctokens)
        );

        assert!(balance::value(&liquidity) > 0, ETooSmall);

        event::emit(RedeemEvent {
            lending_market_id,
            coin_type: type_name::get<T>(),
            reserve_id: object::id_address(reserve),
            ctoken_amount,
            liquidity_amount: balance::value(&liquidity),
        });

        coin::from_balance(liquidity, ctx)
    }


    public fun deposit_ctokens_into_obligation<P, T>(
        lending_market: &mut LendingMarket<P>, 
        reserve_array_index: u64,
        obligation_owner_cap: &ObligationOwnerCap<P>,
        clock: &Clock,
        deposit: Coin<CToken<P, T>>,
        ctx: &mut TxContext
    ) {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        deposit_ctokens_into_obligation_by_id(
            lending_market, 
            reserve_array_index, 
            obligation_owner_cap.obligation_id, 
            clock, 
            deposit, 
            ctx
        )
    }


    /// Borrow tokens of type T. A fee is charged.
    public fun borrow<P, T>(
        lending_market: &mut LendingMarket<P>,
        reserve_array_index: u64,
        obligation_owner_cap: &ObligationOwnerCap<P>,
        clock: &Clock,
        mut amount: u64,
        ctx: &mut TxContext
    ): Coin<T> {
        let lending_market_id = object::id_address(lending_market);
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        assert!(amount > 0, ETooSmall);

        let obligation = object_table::borrow_mut(
            &mut lending_market.obligations, 
            obligation_owner_cap.obligation_id
        );
        obligation::refresh<P>(obligation, &mut lending_market.reserves, clock);

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);

        reserve::compound_interest(reserve, clock);
        reserve::assert_price_is_fresh(reserve, clock);

        if (amount == U64_MAX) {
            amount = max_borrow_amount<P>(lending_market.rate_limiter, obligation, reserve, clock);
            assert!(amount > 0, ETooSmall);
        };

        let (receive_balance, borrow_amount_with_fees) = reserve::borrow_liquidity<P, T>(reserve, amount);
        let origination_fee_amount = borrow_amount_with_fees - balance::value(&receive_balance); 
        obligation::borrow<P>(obligation, reserve, clock, borrow_amount_with_fees);

        let borrow_value = reserve::market_value_upper_bound(reserve, decimal::from(borrow_amount_with_fees));
        rate_limiter::process_qty(
            &mut lending_market.rate_limiter, 
            clock::timestamp_ms(clock) / 1000,
            borrow_value
        );

        event::emit(BorrowEvent {
            lending_market_id,
            coin_type: type_name::get<T>(),
            reserve_id: object::id_address(reserve),
            obligation_id: object::id_address(obligation),
            liquidity_amount: borrow_amount_with_fees,
            origination_fee_amount,
        });

        obligation::zero_out_rewards_if_looped(obligation, &mut lending_market.reserves, clock);
        coin::from_balance(receive_balance, ctx)
    }

    public fun withdraw_ctokens<P, T>(
        lending_market: &mut LendingMarket<P>,
        reserve_array_index: u64,
        obligation_owner_cap: &ObligationOwnerCap<P>,
        clock: &Clock,
        mut amount: u64,
        ctx: &mut TxContext
    ): Coin<CToken<P, T>> {
        let lending_market_id = object::id_address(lending_market);
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        assert!(amount > 0, ETooSmall);

        let obligation = object_table::borrow_mut(
            &mut lending_market.obligations, 
            obligation_owner_cap.obligation_id
        );
        obligation::refresh<P>(obligation, &mut lending_market.reserves, clock);

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);

        if (amount == U64_MAX) {
            amount = max_withdraw_amount<P>(lending_market.rate_limiter, obligation, reserve, clock);
        };

        obligation::withdraw<P>(obligation, reserve, clock, amount);

        event::emit(WithdrawEvent {
            lending_market_id,
            coin_type: type_name::get<T>(),
            reserve_id: object::id_address(reserve),
            obligation_id: object::id_address(obligation),
            ctoken_amount: amount,
        });

        let ctoken_balance = reserve::withdraw_ctokens<P, T>(reserve, amount);

        obligation::zero_out_rewards_if_looped(obligation, &mut lending_market.reserves, clock);
        coin::from_balance(ctoken_balance, ctx)
    }

    /// Liquidate an unhealthy obligation. Leftover repay coins are returned.
    public fun liquidate<P, Repay, Withdraw>(
        lending_market: &mut LendingMarket<P>,
        obligation_id: ID,
        repay_reserve_array_index: u64,
        withdraw_reserve_array_index: u64,
        clock: &Clock,
        repay_coins: &mut Coin<Repay>, // mut because we probably won't use all of it
        ctx: &mut TxContext
    ): (Coin<CToken<P, Withdraw>>, RateLimiterExemption<P, Withdraw>) {
        let lending_market_id = object::id_address(lending_market);
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        assert!(coin::value(repay_coins) > 0, ETooSmall);

        let obligation = object_table::borrow_mut(
            &mut lending_market.obligations, 
            obligation_id
        );
        obligation::refresh<P>(obligation, &mut lending_market.reserves, clock);

        let (withdraw_ctoken_amount, required_repay_amount) = obligation::liquidate<P>(
            obligation, 
            &mut lending_market.reserves,
            repay_reserve_array_index,
            withdraw_reserve_array_index,
            clock,
            coin::value(repay_coins)
        );

        assert!(gt(required_repay_amount, decimal::from(0)), ETooSmall);

        let required_repay_coins = coin::split(repay_coins, ceil(required_repay_amount), ctx);
        let repay_reserve = vector::borrow_mut(&mut lending_market.reserves, repay_reserve_array_index);
        assert!(reserve::coin_type(repay_reserve) == type_name::get<Repay>(), EWrongType);
        reserve::repay_liquidity<P, Repay>(
            repay_reserve, 
            coin::into_balance(required_repay_coins), 
            required_repay_amount
        );

        let withdraw_reserve = vector::borrow_mut(&mut lending_market.reserves, withdraw_reserve_array_index);
        assert!(reserve::coin_type(withdraw_reserve) == type_name::get<Withdraw>(), EWrongType);
        let mut ctokens = reserve::withdraw_ctokens<P, Withdraw>(withdraw_reserve, withdraw_ctoken_amount);
        let (protocol_fee_amount, liquidator_bonus_amount) = reserve::deduct_liquidation_fee<P, Withdraw>(withdraw_reserve, &mut ctokens);
        
        let repay_reserve = vector::borrow(&lending_market.reserves, repay_reserve_array_index);
        let withdraw_reserve = vector::borrow(&lending_market.reserves, withdraw_reserve_array_index);

        event::emit(LiquidateEvent {
            lending_market_id,
            repay_reserve_id: object::id_address(repay_reserve),
            withdraw_reserve_id: object::id_address(withdraw_reserve),
            obligation_id: object::id_address(obligation),
            repay_coin_type: type_name::get<Repay>(),
            withdraw_coin_type: type_name::get<Withdraw>(),
            repay_amount: ceil(required_repay_amount),
            withdraw_amount: withdraw_ctoken_amount,
            protocol_fee_amount,
            liquidator_bonus_amount
        });

        obligation::zero_out_rewards_if_looped(obligation, &mut lending_market.reserves, clock);

        let exemption = RateLimiterExemption<P, Withdraw> { amount: balance::value(&ctokens) };
        (coin::from_balance(ctokens, ctx), exemption)
    }

    public fun repay<P, T>(
        lending_market: &mut LendingMarket<P>,
        reserve_array_index: u64,
        obligation_id: ID,
        clock: &Clock,
        // mut because we might not use all of it and the amount we want to use is 
        // hard to determine beforehand
        max_repay_coins: &mut Coin<T>,
        ctx: &mut TxContext
    ) {
        let lending_market_id = object::id_address(lending_market);
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);

        let obligation = object_table::borrow_mut(
            &mut lending_market.obligations, 
            obligation_id
        );

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);

        reserve::compound_interest(reserve, clock);
        let repay_amount = obligation::repay<P>(
            obligation, 
            reserve, 
            clock,
            decimal::from(coin::value(max_repay_coins))
        );

        let repay_coins = coin::split(max_repay_coins, ceil(repay_amount), ctx);
        reserve::repay_liquidity<P, T>(reserve, coin::into_balance(repay_coins), repay_amount);

        event::emit(RepayEvent {
            lending_market_id,
            coin_type: type_name::get<T>(),
            reserve_id: object::id_address(reserve),
            obligation_id: object::id_address(obligation),
            liquidity_amount: ceil(repay_amount),
        });

        obligation::zero_out_rewards_if_looped(obligation, &mut lending_market.reserves, clock);
    }

    public fun forgive<P, T>(
        _: &LendingMarketOwnerCap<P>, 
        lending_market: &mut LendingMarket<P>,
        reserve_array_index: u64,
        obligation_id: ID,
        clock: &Clock,
        max_forgive_amount: u64,
    ) {
        let lending_market_id = object::id_address(lending_market);
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);

        let obligation = object_table::borrow_mut(
            &mut lending_market.obligations, 
            obligation_id
        );
        obligation::refresh<P>(obligation, &mut lending_market.reserves, clock);

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);

        let forgive_amount = obligation::forgive<P>(
            obligation, 
            reserve, 
            clock,
            decimal::from(max_forgive_amount),
        );

        reserve::forgive_debt<P>(reserve, forgive_amount);

        event::emit(ForgiveEvent {
            lending_market_id,
            coin_type: type_name::get<T>(),
            reserve_id: object::id_address(reserve),
            obligation_id: object::id_address(obligation),
            liquidity_amount: ceil(forgive_amount),
        });

    }

    public fun claim_rewards<P, RewardType>(
        lending_market: &mut LendingMarket<P>,
        cap: &ObligationOwnerCap<P>,
        clock: &Clock,
        reserve_id: u64,
        reward_index: u64,
        is_deposit_reward: bool,
        ctx: &mut TxContext
    ): Coin<RewardType> {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        claim_rewards_by_obligation_id(
            lending_market, 
            cap.obligation_id, 
            clock, 
            reserve_id, 
            reward_index, 
            is_deposit_reward, 
            false,
            ctx
        )
    }

    /// Permissionless function. Anyone can call this function to claim the rewards 
    /// and deposit into the same obligation. This is useful to "crank" rewards for users
    public fun claim_rewards_and_deposit<P, RewardType>(
        lending_market: &mut LendingMarket<P>,
        obligation_id: ID,
        clock: &Clock,
        // array index of reserve that is giving out the rewards
        reward_reserve_id: u64,
        reward_index: u64,
        is_deposit_reward: bool,
        // array index of reserve with type RewardType
        deposit_reserve_id: u64,
        ctx: &mut TxContext
    ) {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);

        let mut rewards = claim_rewards_by_obligation_id<P, RewardType>(
            lending_market, 
            obligation_id, 
            clock, 
            reward_reserve_id, 
            reward_index, 
            is_deposit_reward, 
            true,
            ctx
        );

        let obligation = object_table::borrow(&lending_market.obligations, obligation_id);
        if (gt(obligation::borrowed_amount<P, RewardType>(obligation), decimal::from(0))) {
            repay<P, RewardType>(
                lending_market,
                deposit_reserve_id,
                obligation_id,
                clock,
                &mut rewards,
                ctx
            );
        };

        let expected_ctokens = {
            let deposit_reserve = vector::borrow(&lending_market.reserves, deposit_reserve_id);
            assert!(reserve::coin_type(deposit_reserve) == type_name::get<RewardType>(), EWrongType);

            floor(
                div(
                    decimal::from(coin::value(&rewards)),
                    reserve::ctoken_ratio(deposit_reserve)
                )
            )
        };

        if (expected_ctokens == 0) {
            transfer::public_transfer(rewards, lending_market.fee_receiver);
        }
        else {
            let ctokens = deposit_liquidity_and_mint_ctokens<P, RewardType>(
                lending_market, 
                deposit_reserve_id, 
                clock, 
                rewards, 
                ctx
            );

            deposit_ctokens_into_obligation_by_id<P, RewardType>(
                lending_market, 
                deposit_reserve_id, 
                obligation_id, 
                clock, 
                ctokens, 
                ctx
            );
        }
    }


    // === Public-View Functions ===
    fun max_borrow_amount<P>(
        mut rate_limiter: RateLimiter,
        obligation: &Obligation<P>, 
        reserve: &Reserve<P>,
        clock: &Clock
    ): u64 {
        let remaining_outflow_usd = rate_limiter::remaining_outflow(
            &mut rate_limiter, 
            clock::timestamp_ms(clock) / 1000
        );

        let rate_limiter_max_borrow_amount = saturating_floor(reserve::usd_to_token_amount_lower_bound(
            reserve, 
            min(remaining_outflow_usd, decimal::from(1_000_000_000))
        ));

        let max_borrow_amount_including_fees = sui::math::min(
            sui::math::min(
                obligation::max_borrow_amount(obligation, reserve),
                reserve::max_borrow_amount(reserve)
            ),
            rate_limiter_max_borrow_amount
        );

        // account for fee
        let mut max_borrow_amount = floor(div(
            decimal::from(max_borrow_amount_including_fees),
            add(decimal::from(1), borrow_fee(reserve::config(reserve)))
        ));

        let fee = ceil(mul(
            decimal::from(max_borrow_amount), 
            borrow_fee(reserve::config(reserve))
        ));

        // since the fee is ceiling'd, we need to subtract 1 from the max_borrow_amount in certain
        // cases
        if (max_borrow_amount + fee > max_borrow_amount_including_fees && max_borrow_amount > 0) {
            max_borrow_amount = max_borrow_amount - 1;
        };

        max_borrow_amount
    }

    // maximum amount that can be withdrawn and redeemed
    fun max_withdraw_amount<P>(
        mut rate_limiter: RateLimiter,
        obligation: &Obligation<P>, 
        reserve: &Reserve<P>,
        clock: &Clock
    ): u64 {
        let remaining_outflow_usd = rate_limiter::remaining_outflow(
            &mut rate_limiter, 
            clock::timestamp_ms(clock) / 1000
        );

        let rate_limiter_max_withdraw_amount = reserve::usd_to_token_amount_lower_bound(
            reserve, 
            min(remaining_outflow_usd, decimal::from(1_000_000_000))
        );

        let rate_limiter_max_withdraw_ctoken_amount = floor(div(
            rate_limiter_max_withdraw_amount,
            reserve::ctoken_ratio(reserve)
        ));

        sui::math::min(
            sui::math::min(
                obligation::max_withdraw_amount(obligation, reserve),
                rate_limiter_max_withdraw_ctoken_amount
            ),
            reserve::max_redeem_amount(reserve)
        )
    }

    public fun obligation_id<P>(cap: &ObligationOwnerCap<P>): ID {
        cap.obligation_id
    }

    // slow function. use sparingly.
    fun reserve_array_index<P, T>(lending_market: &LendingMarket<P>): u64 {
        let mut i = 0;
        while (i < vector::length(&lending_market.reserves)) {
            let reserve = vector::borrow(&lending_market.reserves, i);
            if (reserve::coin_type(reserve) == type_name::get<T>()) {
                return i
            };

            i = i + 1;
        };

        i
    }

    public fun reserve<P, T>(lending_market: &LendingMarket<P>): &Reserve<P> {
        let i = reserve_array_index<P, T>(lending_market);
        vector::borrow(&lending_market.reserves, i)
    }

    public fun obligation<P>(lending_market: &LendingMarket<P>, obligation_id: ID): &Obligation<P> {
        object_table::borrow(&lending_market.obligations, obligation_id)
    }

    // === Admin Functions ===
    entry fun migrate<P>(
        _: &LendingMarketOwnerCap<P>,
        lending_market: &mut LendingMarket<P>,
    ) {
        assert!(lending_market.version == CURRENT_VERSION - 1, EIncorrectVersion);
        lending_market.version = CURRENT_VERSION;
    }

    public fun add_reserve<P, T>(
        _: &LendingMarketOwnerCap<P>, 
        lending_market: &mut LendingMarket<P>, 
        price_info: &PriceInfoObject,
        config: ReserveConfig,
        coin_metadata: &CoinMetadata<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        assert!(reserve_array_index<P, T>(lending_market) == vector::length(&lending_market.reserves), EDuplicateReserve);

        let reserve = reserve::create_reserve<P, T>(
            object::id(lending_market),
            config, 
            vector::length(&lending_market.reserves),
            coin_metadata, 
            price_info, 
            clock, 
            ctx
        );

        vector::push_back(&mut lending_market.reserves, reserve);
    }

    public fun update_reserve_config<P, T>(
        _: &LendingMarketOwnerCap<P>, 
        lending_market: &mut LendingMarket<P>, 
        reserve_array_index: u64,
        config: ReserveConfig,
    ) {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);

        reserve::update_reserve_config<P>(reserve, config);
    }
    
    public fun change_reserve_price_feed<P, T>(
        _: &LendingMarketOwnerCap<P>, 
        lending_market: &mut LendingMarket<P>, 
        reserve_array_index: u64,
        price_info_obj: &PriceInfoObject,
        clock: &Clock,
    ) {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);

        reserve::change_price_feed<P>(reserve, price_info_obj, clock);
    }

    public fun add_pool_reward<P, RewardType>(
        _: &LendingMarketOwnerCap<P>, 
        lending_market: &mut LendingMarket<P>, 
        reserve_array_index: u64,
        is_deposit_reward: bool,
        rewards: Coin<RewardType>,
        start_time_ms: u64,
        end_time_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        let pool_reward_manager = if (is_deposit_reward) {
            reserve::deposits_pool_reward_manager_mut(reserve)
        } else {
            reserve::borrows_pool_reward_manager_mut(reserve)
        };

        liquidity_mining::add_pool_reward<RewardType>(
            pool_reward_manager, 
            coin::into_balance(rewards), 
            start_time_ms, 
            end_time_ms,
            clock,
            ctx
        );
    }

    public fun cancel_pool_reward<P, RewardType>(
        _: &LendingMarketOwnerCap<P>, 
        lending_market: &mut LendingMarket<P>, 
        reserve_array_index: u64,
        is_deposit_reward: bool,
        reward_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<RewardType> {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        let pool_reward_manager = if (is_deposit_reward) {
            reserve::deposits_pool_reward_manager_mut(reserve)
        } else {
            reserve::borrows_pool_reward_manager_mut(reserve)
        };

        let unallocated_rewards = liquidity_mining::cancel_pool_reward<RewardType>(
            pool_reward_manager, 
            reward_index, 
            clock
        );

        coin::from_balance(unallocated_rewards, ctx)
    }

    public fun close_pool_reward<P, RewardType>(
        _: &LendingMarketOwnerCap<P>, 
        lending_market: &mut LendingMarket<P>, 
        reserve_array_index: u64,
        is_deposit_reward: bool,
        reward_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<RewardType> {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        let pool_reward_manager = if (is_deposit_reward) {
            reserve::deposits_pool_reward_manager_mut(reserve)
        } else {
            reserve::borrows_pool_reward_manager_mut(reserve)
        };

        let unallocated_rewards = liquidity_mining::close_pool_reward<RewardType>(
            pool_reward_manager, 
            reward_index, 
            clock
        );

        coin::from_balance(unallocated_rewards, ctx)
    }

    public fun update_rate_limiter_config<P>(
        _: &LendingMarketOwnerCap<P>, 
        lending_market: &mut LendingMarket<P>, 
        clock: &Clock,
        config: RateLimiterConfig,
    ) {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        lending_market.rate_limiter = rate_limiter::new(config, clock::timestamp_ms(clock) / 1000);
    }

    entry fun claim_fees<P, T>(
        lending_market: &mut LendingMarket<P>,
        reserve_array_index: u64,
        ctx: &mut TxContext
    ) {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);
        let (ctoken_fees, fees) = reserve::claim_fees<P, T>(reserve);

        transfer::public_transfer(coin::from_balance(ctoken_fees, ctx), lending_market.fee_receiver);
        transfer::public_transfer(coin::from_balance(fees, ctx), lending_market.fee_receiver);
    }

    public fun new_obligation_owner_cap<P>(
        _: &LendingMarketOwnerCap<P>,
        lending_market: &LendingMarket<P>,
        obligation_id: ID,
        ctx: &mut TxContext
    ): ObligationOwnerCap<P> {
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        assert!(object_table::contains(&lending_market.obligations, obligation_id), EInvalidObligationId);

        let cap = ObligationOwnerCap<P> { 
            id: object::new(ctx), 
            obligation_id: obligation_id
        };

        cap
    }

    // === Private Functions ===
    fun deposit_ctokens_into_obligation_by_id<P, T>(
        lending_market: &mut LendingMarket<P>, 
        reserve_array_index: u64,
        obligation_id: ID,
        clock: &Clock,
        deposit: Coin<CToken<P, T>>,
        _ctx: &mut TxContext
    ) {
        let lending_market_id = object::id_address(lending_market);
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);
        assert!(coin::value(&deposit) > 0, ETooSmall);

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_array_index);
        assert!(reserve::coin_type(reserve) == type_name::get<T>(), EWrongType);

        let obligation = object_table::borrow_mut(
            &mut lending_market.obligations, 
            obligation_id
        );

        event::emit(DepositEvent {
            lending_market_id,
            coin_type: type_name::get<T>(),
            reserve_id: object::id_address(reserve),
            obligation_id: object::id_address(obligation),
            ctoken_amount: coin::value(&deposit),
        });

        obligation::deposit<P>(
            obligation, 
            reserve,
            clock,
            coin::value(&deposit)
        );
        reserve::deposit_ctokens<P, T>(reserve, coin::into_balance(deposit));

        obligation::zero_out_rewards_if_looped(obligation, &mut lending_market.reserves, clock);
    }

    fun claim_rewards_by_obligation_id<P, RewardType>(
        lending_market: &mut LendingMarket<P>,
        obligation_id: ID,
        clock: &Clock,
        reserve_id: u64,
        reward_index: u64,
        is_deposit_reward: bool,
        fail_if_reward_period_not_over: bool,
        ctx: &mut TxContext
    ): Coin<RewardType> {
        let lending_market_id = object::id_address(lending_market);
        assert!(lending_market.version == CURRENT_VERSION, EIncorrectVersion);

        assert!(
            type_name::borrow_string(&type_name::get<RewardType>()) != 
            &ascii::string(b"34fe4f3c9e450fed4d0a3c587ed842eec5313c30c3cc3c0841247c49425e246b::suilend_point::SUILEND_POINT"),
            ECannotClaimReward
        );

        let obligation = object_table::borrow_mut(
            &mut lending_market.obligations, 
            obligation_id
        );

        let reserve = vector::borrow_mut(&mut lending_market.reserves, reserve_id);
        reserve::compound_interest(reserve, clock);

        let pool_reward_manager = if (is_deposit_reward) {
            reserve::deposits_pool_reward_manager_mut(reserve)
        } else {
            reserve::borrows_pool_reward_manager_mut(reserve)
        };

        if (fail_if_reward_period_not_over) {
            let pool_reward = option::borrow(liquidity_mining::pool_reward(pool_reward_manager, reward_index));
            assert!(clock::timestamp_ms(clock) >= liquidity_mining::end_time_ms(pool_reward), ERewardPeriodNotOver);
        };

        let rewards = coin::from_balance(
            obligation::claim_rewards<P, RewardType>(
                obligation, 
                pool_reward_manager,
                clock,
                reward_index
            ),
            ctx
        );

        let pool_reward_id = liquidity_mining::pool_reward_id(pool_reward_manager, reward_index);

        event::emit(ClaimRewardEvent {
            lending_market_id,
            reserve_id: object::id_address(reserve),
            obligation_id: object::id_address(obligation),

            is_deposit_reward,
            pool_reward_id: object::id_to_address(&pool_reward_id),
            coin_type: type_name::get<RewardType>(),
            liquidity_amount: coin::value(&rewards),
        });

        rewards
    }

    // === Test Functions ===
    #[test_only]
    public fun destroy_for_testing<P>(obligation_owner_cap: ObligationOwnerCap<P>) {
        let ObligationOwnerCap { id, obligation_id: _ } = obligation_owner_cap;
        object::delete(id);
    }

    #[test_only]
    public fun destroy_lending_market_owner_cap_for_testing<P>(lending_market_owner_cap: LendingMarketOwnerCap<P>) {
        let LendingMarketOwnerCap { id, lending_market_id: _ } = lending_market_owner_cap;
        object::delete(id);
    }

    #[test_only]
    public fun fee_receiver<P>(lending_market: &LendingMarket<P>): address {
        lending_market.fee_receiver
    }

    #[test_only]
    public use fun rate_limiter_exemption_amount as RateLimiterExemption.amount;

    #[test_only]
    public fun rate_limiter_exemption_amount<P, T>(exemption: &RateLimiterExemption<P, T>): u64 {
        exemption.amount
    }

    // #[test_only]
    // const MILLISECONDS_IN_DAY: u64 = 86_400_000;

    // #[test]
    // fun test_liquidity_mining() {
    //     use sui::test_utils::{Self};
    //     use suilend::test_usdc::{TEST_USDC};
    //     use suilend::test_sui::{TEST_SUI};
    //     use suilend::reserve_config::{Self, default_reserve_config};
    //     use suilend::mock_pyth::{Self};

    //     use std::type_name::{Self};

    //     let owner = @0x26;

    //     let mut scenario = test_scenario::begin(owner);
    //     let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
    //         let mut bag = bag::new(test_scenario::ctx(&mut scenario));
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_USDC>(), 
    //             ReserveArgs {
    //                 config: {
    //                     let config = default_reserve_config();
    //                     let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
    //                     reserve_config::set_open_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_close_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_max_close_ltv_pct(&mut builder, 50);
    //                     sui::test_utils::destroy(config);

    //                     reserve_config::build(builder, test_scenario::ctx(&mut scenario))
    //                 },
    //                 initial_deposit: 100 * 1_000_000
    //             }
    //         );
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_SUI>(), 
    //             ReserveArgs {
    //                 config: reserve_config::default_reserve_config(),
    //                 initial_deposit: 100 * 1_000_000_000
    //             }
    //         );

    //         bag
    //     }, &mut scenario);

    //     let usdc_rewards = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
    //     let sui_rewards = coin::mint_for_testing<TEST_SUI>(100 * 1_000_000_000, test_scenario::ctx(&mut scenario));

    //     add_pool_reward<LENDING_MARKET, TEST_USDC>(
    //         &owner_cap,
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         true,
    //         usdc_rewards,
    //         0,
    //         10 * MILLISECONDS_IN_DAY,
    //         &clock,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     add_pool_reward<LENDING_MARKET, TEST_SUI>(
    //         &owner_cap,
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         true,
    //         sui_rewards,
    //         4 * MILLISECONDS_IN_DAY,
    //         14 * MILLISECONDS_IN_DAY,
    //         &clock,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     clock::set_for_testing(&mut clock, 1 * MILLISECONDS_IN_DAY);

    //     // create obligation
    //     let obligation_owner_cap = create_obligation(
    //         &mut lending_market,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
    //     let ctokens = deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &clock,
    //         coins,
    //         test_scenario::ctx(&mut scenario)
    //     );
    //     deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &obligation_owner_cap,
    //         &clock,
    //         ctokens,
    //         test_scenario::ctx(&mut scenario)
    //     );


    //     // set reserve parameters and prices
    //     mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    //     mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

    //     refresh_reserve_price<LENDING_MARKET>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &clock,
    //         mock_pyth::get_price_obj<TEST_USDC>(&prices)
    //     );
    //     refresh_reserve_price<LENDING_MARKET>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         &clock,
    //         mock_pyth::get_price_obj<TEST_SUI>(&prices)
    //     );
    //     let sui = borrow<LENDING_MARKET, TEST_SUI>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         &obligation_owner_cap,
    //         &clock,
    //         1_000_000_000,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     clock::set_for_testing(&mut clock, 9 * MILLISECONDS_IN_DAY);
    //     let claimed_usdc = claim_rewards<LENDING_MARKET, TEST_USDC>(
    //         &mut lending_market,
    //         &obligation_owner_cap,
    //         &clock,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         0,
    //         true,
    //         test_scenario::ctx(&mut scenario)
    //     );
    //     assert!(coin::value(&claimed_usdc) == 80 * 1_000_000, 0);

    //     // this fails because but rewards period is not over
    //     // claim_rewards_and_deposit<LENDING_MARKET, TEST_SUI>(
    //     //     &mut lending_market,
    //     //     obligation_owner_cap.obligation_id,
    //     //     &clock,
    //     //     *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //     //     1,
    //     //     true,
    //     //     *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //     //     test_scenario::ctx(&mut scenario)
    //     // );

    //     let remaining_sui_rewards = cancel_pool_reward<LENDING_MARKET, TEST_SUI>(
    //         &owner_cap,
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         true,
    //         1,
    //         &clock,
    //         test_scenario::ctx(&mut scenario)
    //     );
    //     assert!(coin::value(&remaining_sui_rewards) == 50 * 1_000_000_000, 0);

    //     claim_rewards_and_deposit<LENDING_MARKET, TEST_SUI>(
    //         &mut lending_market,
    //         obligation_owner_cap.obligation_id,
    //         &clock,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         1,
    //         true,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     assert!(obligation::deposited_ctoken_amount<LENDING_MARKET, TEST_SUI>(
    //         obligation(&lending_market, obligation_id(&obligation_owner_cap))
    //     ) == 49 * 1_000_000_000, 0);
    //     assert!(obligation::borrowed_amount<LENDING_MARKET, TEST_SUI>(
    //         obligation(&lending_market, obligation_id(&obligation_owner_cap))
    //     ) == decimal::from(0), 0);

    //     let dust_sui_rewards = close_pool_reward<LENDING_MARKET, TEST_SUI>(
    //         &owner_cap,
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         true,
    //         1,
    //         &clock,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     assert!(coin::value(&dust_sui_rewards) == 0, 0);

    //     test_utils::destroy(dust_sui_rewards);
    //     test_utils::destroy(remaining_sui_rewards);
    //     test_utils::destroy(sui);
    //     test_utils::destroy(owner_cap);
    //     test_utils::destroy(obligation_owner_cap);
    //     test_utils::destroy(claimed_usdc);
    //     test_utils::destroy(lending_market);
    //     test_utils::destroy(clock);
    //     test_utils::destroy(prices);
    //     test_utils::destroy(type_to_index);
    //     test_scenario::end(scenario);

    // }

    // #[test]
    // public fun test_forgive_debt() {
    //     use sui::test_utils::{Self};
    //     use suilend::test_usdc::{TEST_USDC};
    //     use suilend::test_sui::{TEST_SUI};
    //     use suilend::mock_pyth::{Self};
    //     use suilend::reserve_config::{Self, default_reserve_config};
    //     use suilend::decimal::{sub, eq};

    //     use std::type_name::{Self};

    //     let owner = @0x26;
    //     let mut scenario = test_scenario::begin(owner);
    //     let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
    //         let mut bag = bag::new(test_scenario::ctx(&mut scenario));
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_USDC>(), 
    //             ReserveArgs {
    //                 config: {
    //                     let config = default_reserve_config();
    //                     let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
    //                     reserve_config::set_open_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_close_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_max_close_ltv_pct(&mut builder, 50);
    //                     sui::test_utils::destroy(config);

    //                     reserve_config::build(builder, test_scenario::ctx(&mut scenario))
    //                 },
    //                 initial_deposit: 100 * 1_000_000
    //             }
    //         );
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_SUI>(), 
    //             ReserveArgs {
    //                 config: reserve_config::default_reserve_config(),
    //                 initial_deposit: 100 * 1_000_000_000
    //             }
    //         );

    //         bag
    //     }, &mut scenario);

    //     clock::set_for_testing(&mut clock, 1 * 1000);

    //     // set reserve parameters and prices
    //     mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    //     mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

    //     // create obligation
    //     let obligation_owner_cap = create_obligation(
    //         &mut lending_market,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
    //     let ctokens = deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &clock,
    //         coins,
    //         test_scenario::ctx(&mut scenario)
    //     );
    //     deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &obligation_owner_cap,
    //         &clock,
    //         ctokens,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     refresh_reserve_price<LENDING_MARKET>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &clock,
    //         mock_pyth::get_price_obj<TEST_USDC>(&prices)
    //     );
    //     refresh_reserve_price<LENDING_MARKET>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         &clock,
    //         mock_pyth::get_price_obj<TEST_SUI>(&prices)
    //     );

    //     let sui = borrow<LENDING_MARKET, TEST_SUI>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         &obligation_owner_cap,
    //         &clock,
    //         5 * 1_000_000_000,
    //         test_scenario::ctx(&mut scenario)
    //     );
    //     test_utils::destroy(sui);

    //     mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 2, &clock); // $10
    //     refresh_reserve_price<LENDING_MARKET>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         &clock,
    //         mock_pyth::get_price_obj<TEST_SUI>(&prices)
    //     );

    //     // liquidate the obligation
    //     let mut sui = coin::mint_for_testing<TEST_SUI>(1 * 1_000_000_000, test_scenario::ctx(&mut scenario));
    //     let (usdc, _exemption) = liquidate<LENDING_MARKET, TEST_SUI, TEST_USDC>(
    //         &mut lending_market,
    //         obligation_id(&obligation_owner_cap),
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &clock,
    //         &mut sui,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     let obligation = obligation(&lending_market, obligation_id(&obligation_owner_cap));
    //     let sui_reserve = reserve<LENDING_MARKET, TEST_SUI>(&lending_market);
    //     let old_reserve_borrowed_amount = reserve::borrowed_amount<LENDING_MARKET>(sui_reserve);
    //     let old_borrowed_amount = obligation::borrowed_amount<LENDING_MARKET, TEST_SUI>(obligation);

    //     forgive<LENDING_MARKET, TEST_SUI>(
    //         &owner_cap,
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         obligation_id(&obligation_owner_cap),
    //         &clock,
    //         1_000_000_000,
    //     );

    //     let obligation = obligation(&lending_market, obligation_id(&obligation_owner_cap));
    //     let sui_reserve = reserve<LENDING_MARKET, TEST_SUI>(&lending_market);
    //     let reserve_borrowed_amount = reserve::borrowed_amount<LENDING_MARKET>(sui_reserve);
    //     let borrowed_amount = obligation::borrowed_amount<LENDING_MARKET, TEST_SUI>(obligation);

    //     assert!(eq(sub(old_borrowed_amount, borrowed_amount), decimal::from(1_000_000_000)), 0);
    //     assert!(eq(sub(old_reserve_borrowed_amount, reserve_borrowed_amount), decimal::from(1_000_000_000)), 0);

    //     test_utils::destroy(usdc);
    //     test_utils::destroy(sui);
    //     test_utils::destroy(obligation_owner_cap);
    //     test_utils::destroy(owner_cap);
    //     test_utils::destroy(lending_market);
    //     test_utils::destroy(clock);
    //     test_utils::destroy(prices);
    //     test_utils::destroy(type_to_index);
    //     test_scenario::end(scenario);
    // }

    //  #[test]
    // public fun test_max_borrow() {
    //     use sui::test_utils::{Self};
    //     use suilend::test_usdc::{TEST_USDC};
    //     use suilend::test_sui::{TEST_SUI};
    //     use suilend::mock_pyth::{Self};
    //     use suilend::reserve_config::{Self, default_reserve_config};

    //     use std::type_name::{Self};

    //     let owner = @0x26;
    //     let mut scenario = test_scenario::begin(owner);
    //     let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
    //         let mut bag = bag::new(test_scenario::ctx(&mut scenario));
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_USDC>(), 
    //             ReserveArgs {
    //                 config: {
    //                     let config = default_reserve_config();
    //                     let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
    //                     reserve_config::set_open_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_close_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_max_close_ltv_pct(&mut builder, 50);
    //                     sui::test_utils::destroy(config);

    //                     reserve_config::build(builder, test_scenario::ctx(&mut scenario))
    //                 },
    //                 initial_deposit: 100 * 1_000_000
    //             }
    //         );
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_SUI>(), 
    //             ReserveArgs {
    //                 config: {
    //                     let config = reserve_config::default_reserve_config();
    //                     let mut builder = reserve_config::from(
    //                         &config,
    //                         test_scenario::ctx(&mut scenario)
    //                     );

    //                     test_utils::destroy(config);

    //                     reserve_config::set_borrow_fee_bps(&mut builder, 10);
    //                     // reserve_config::set_borrow_limit(&mut builder, 4 * 1_000_000_000);
    //                     // reserve_config::set_borrow_limit_usd(&mut builder, 20);
    //                     reserve_config::build(builder, test_scenario::ctx(&mut scenario))
    //                 },
    //                 initial_deposit: 100 * 1_000_000_000
    //             }
    //         );

    //         bag
    //     }, &mut scenario);

    //     clock::set_for_testing(&mut clock, 1 * 1000);

    //     // set reserve parameters and prices
    //     mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    //     mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

    //     // create obligation
    //     let obligation_owner_cap = create_obligation(
    //         &mut lending_market,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
    //     let ctokens = deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &clock,
    //         coins,
    //         test_scenario::ctx(&mut scenario)
    //     );
    //     deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &obligation_owner_cap,
    //         &clock,
    //         ctokens,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     refresh_reserve_price<LENDING_MARKET>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &clock,
    //         mock_pyth::get_price_obj<TEST_USDC>(&prices)
    //     );
    //     refresh_reserve_price<LENDING_MARKET>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         &clock,
    //         mock_pyth::get_price_obj<TEST_SUI>(&prices)
    //     );

    //     let sui = borrow<LENDING_MARKET, TEST_SUI>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         &obligation_owner_cap,
    //         &clock,
    //         U64_MAX,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     assert!(coin::value(&sui) == 4_995_004_995, 0);

    //     test_utils::destroy(sui);
    //     test_utils::destroy(obligation_owner_cap);
    //     test_utils::destroy(owner_cap);
    //     test_utils::destroy(lending_market);
    //     test_utils::destroy(clock);
    //     test_utils::destroy(prices);
    //     test_utils::destroy(type_to_index);
    //     test_scenario::end(scenario);
    // }

    // #[test]
    // public fun test_max_withdraw() {
    //     use sui::test_utils::{Self};
    //     use suilend::test_usdc::{TEST_USDC};
    //     use suilend::test_sui::{TEST_SUI};
    //     use suilend::mock_pyth::{Self};
    //     use suilend::reserve_config::{Self, default_reserve_config};

    //     use std::type_name::{Self};

    //     let owner = @0x26;
    //     let mut scenario = test_scenario::begin(owner);
    //     let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
    //         let mut bag = bag::new(test_scenario::ctx(&mut scenario));
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_USDC>(), 
    //             ReserveArgs {
    //                 config: {
    //                     let config = default_reserve_config();
    //                     let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
    //                     reserve_config::set_open_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_close_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_max_close_ltv_pct(&mut builder, 50);
    //                     sui::test_utils::destroy(config);

    //                     reserve_config::build(builder, test_scenario::ctx(&mut scenario))
    //                 },
    //                 initial_deposit: 100 * 1_000_000
    //             }
    //         );
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_SUI>(), 
    //             ReserveArgs {
    //                 config: {
    //                     let config = default_reserve_config();
    //                     let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
    //                     reserve_config::set_borrow_weight_bps(&mut builder, 20_000);
    //                     sui::test_utils::destroy(config);

    //                     reserve_config::build(builder, test_scenario::ctx(&mut scenario))
    //                 },
    //                 initial_deposit: 100 * 1_000_000_000
    //             }
    //         );

    //         bag
    //     }, &mut scenario);

    //     clock::set_for_testing(&mut clock, 1 * 1000);

    //     // set reserve parameters and prices
    //     mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    //     mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

    //     // create obligation
    //     let obligation_owner_cap = create_obligation(
    //         &mut lending_market,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     let coins = coin::mint_for_testing<TEST_USDC>(200 * 1_000_000, test_scenario::ctx(&mut scenario));
    //     let ctokens = deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &clock,
    //         coins,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &obligation_owner_cap,
    //         &clock,
    //         ctokens,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     refresh_reserve_price<LENDING_MARKET>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &clock,
    //         mock_pyth::get_price_obj<TEST_USDC>(&prices)
    //     );
    //     refresh_reserve_price<LENDING_MARKET>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         &clock,
    //         mock_pyth::get_price_obj<TEST_SUI>(&prices)
    //     );

    //     let sui = borrow<LENDING_MARKET, TEST_SUI>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
    //         &obligation_owner_cap,
    //         &clock,
    //         2_500_000_000,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     update_rate_limiter_config<LENDING_MARKET>(
    //         &owner_cap,
    //         &mut lending_market,
    //         &clock,
    //         rate_limiter::new_config(1, 10) // disabled
    //     );

    //     let cusdc = withdraw_ctokens<LENDING_MARKET, TEST_USDC>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &obligation_owner_cap,
    //         &clock,
    //         U64_MAX,
    //         test_scenario::ctx(&mut scenario)
    //     );
    //     let usdc = redeem_ctokens_and_withdraw_liquidity<LENDING_MARKET, TEST_USDC>(
    //         &mut lending_market,
    //         *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
    //         &clock,
    //         cusdc,
    //         option::none(),
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     assert!(coin::value(&usdc) == 10 * 1_000_000, 0);

    //     test_utils::destroy(sui);
    //     test_utils::destroy(usdc);
    //     test_utils::destroy(obligation_owner_cap);
    //     test_utils::destroy(owner_cap);
    //     test_utils::destroy(lending_market);
    //     test_utils::destroy(clock);
    //     test_utils::destroy(prices);
    //     test_utils::destroy(type_to_index);
    //     test_scenario::end(scenario);
    // }

    // #[test]
    // public fun test_change_pyth_price_feed() {
    //     use sui::test_utils::{Self, assert_eq};
    //     use sui::test_scenario::ctx;
    //     use suilend::test_usdc::{TEST_USDC};
    //     use suilend::test_sui::{TEST_SUI};
    //     use suilend::mock_pyth::{Self};
    //     use suilend::reserve_config::{Self, default_reserve_config};

    //     use std::type_name::{Self};

    //     let owner = @0x26;
    //     let mut scenario = test_scenario::begin(owner);
    //     let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
    //         let mut bag = bag::new(test_scenario::ctx(&mut scenario));
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_USDC>(), 
    //             ReserveArgs {
    //                 config: {
    //                     let config = default_reserve_config();
    //                     let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
    //                     reserve_config::set_open_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_close_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_max_close_ltv_pct(&mut builder, 50);
    //                     sui::test_utils::destroy(config);

    //                     reserve_config::build(builder, test_scenario::ctx(&mut scenario))
    //                 },
    //                 initial_deposit: 100 * 1_000_000
    //             }
    //         );
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_SUI>(), 
    //             ReserveArgs {
    //                 config: {
    //                     let config = default_reserve_config();
    //                     let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
    //                     reserve_config::set_borrow_weight_bps(&mut builder, 20_000);
    //                     sui::test_utils::destroy(config);

    //                     reserve_config::build(builder, test_scenario::ctx(&mut scenario))
    //                 },
    //                 initial_deposit: 100 * 1_000_000_000
    //             }
    //         );

    //         bag
    //     }, &mut scenario);

    //     clock::set_for_testing(&mut clock, 1 * 1000);

    //     // change the price feed as admin
    //     let new_price_info_obj = mock_pyth::new_price_info_obj(3_u8, ctx(&mut scenario));

    //     let array_idx = *bag::borrow(&type_to_index, type_name::get<TEST_USDC>());

    //     change_reserve_price_feed<LENDING_MARKET, TEST_USDC>(
    //         &owner_cap,
    //         &mut lending_market,
    //         array_idx,
    //         &new_price_info_obj,
    //         &clock,
    //     );

    //     // TODO: assert changes
    //     let reserve_ref = reserve<LENDING_MARKET, TEST_USDC>(&lending_market);
    //     let price_id = pyth::price_info::get_price_identifier(
    //         &pyth::price_info::get_price_info_from_price_info_object(&new_price_info_obj)
    //     );

    //     assert_eq(*reserve::price_identifier(reserve_ref), price_id);

    //     test_utils::destroy(owner_cap);
    //     test_utils::destroy(lending_market);
    //     test_utils::destroy(clock);
    //     test_utils::destroy(prices);
    //     test_utils::destroy(type_to_index);
    //     test_utils::destroy(new_price_info_obj);
    //     test_scenario::end(scenario);
    // }
    
    // #[test]
    // public fun test_admin_new_obligation_cap() {
    //     use sui::test_utils::{Self};
    //     use suilend::test_usdc::{TEST_USDC};
    //     use suilend::test_sui::{TEST_SUI};
    //     use suilend::mock_pyth::{Self};
    //     use suilend::reserve_config::{Self, default_reserve_config};

    //     use std::type_name::{Self};

    //     let owner = @0x26;
    //     let mut scenario = test_scenario::begin(owner);
    //     let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
    //         let mut bag = bag::new(test_scenario::ctx(&mut scenario));
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_USDC>(), 
    //             ReserveArgs {
    //                 config: {
    //                     let config = default_reserve_config();
    //                     let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
    //                     reserve_config::set_open_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_close_ltv_pct(&mut builder, 50);
    //                     reserve_config::set_max_close_ltv_pct(&mut builder, 50);
    //                     sui::test_utils::destroy(config);

    //                     reserve_config::build(builder, test_scenario::ctx(&mut scenario))
    //                 },
    //                 initial_deposit: 100 * 1_000_000
    //             }
    //         );
    //         bag::add(
    //             &mut bag, 
    //             type_name::get<TEST_SUI>(), 
    //             ReserveArgs {
    //                 config: {
    //                     let config = default_reserve_config();
    //                     let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
    //                     reserve_config::set_borrow_weight_bps(&mut builder, 20_000);
    //                     sui::test_utils::destroy(config);

    //                     reserve_config::build(builder, test_scenario::ctx(&mut scenario))
    //                 },
    //                 initial_deposit: 100 * 1_000_000_000
    //             }
    //         );

    //         bag
    //     }, &mut scenario);

    //     clock::set_for_testing(&mut clock, 1 * 1000);

    //     // set reserve parameters and prices
    //     mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
    //     mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

    //     // create obligation
    //     let obligation_owner_cap = create_obligation(
    //         &mut lending_market,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     let obligation_id = obligation_owner_cap.obligation_id;

    //     // Mock accidental burning of obligation cap
    //     transfer::public_transfer(obligation_owner_cap, @0x0);

    //     let obligation_owner_cap = new_obligation_owner_cap(
    //         &owner_cap,
    //         &lending_market,
    //         obligation_id,
    //         test_scenario::ctx(&mut scenario)
    //     );

    //     assert!(obligation_owner_cap.obligation_id == obligation_id, 0);

    //     test_utils::destroy(obligation_owner_cap);
    //     test_utils::destroy(owner_cap);
    //     test_utils::destroy(lending_market);
    //     test_utils::destroy(clock);
    //     test_utils::destroy(prices);
    //     test_utils::destroy(type_to_index);
    //     test_scenario::end(scenario);
    // }
}
