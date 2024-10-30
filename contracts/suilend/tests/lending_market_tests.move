module suilend::lending_market_tests {
    use sui::test_scenario::{Self, Scenario};
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
    use suilend::lending_market::{Self, create_lending_market, LendingMarketOwnerCap, LendingMarket};
    use suilend::mock_pyth::{PriceState};


    public struct LENDING_MARKET has drop {}

    const U64_MAX: u64 = 18446744073709551615;

    #[test]
    fun test_create_lending_market() {
        use sui::test_scenario::{Self};
        use sui::test_utils::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);

        let (owner_cap, lending_market) = create_lending_market<LENDING_MARKET>(
            test_scenario::ctx(&mut scenario)
        );

        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = suilend::lending_market::EDuplicateReserve)]
    fun duplicate_reserves() {
        use suilend::test_usdc::{TEST_USDC};
        use suilend::test_sui::{TEST_SUI};
        use suilend::reserve_config::{Self};
        use sui::test_utils::{Self};
        use suilend::mock_pyth::{Self};
        use suilend::mock_metadata::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);

        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        let metadata = mock_metadata::init_metadata(test_scenario::ctx(&mut scenario));

        let (owner_cap, mut lending_market) = create_lending_market<LENDING_MARKET>(
            test_scenario::ctx(&mut scenario)
        );

        let mut prices = mock_pyth::init_state(test_scenario::ctx(&mut scenario));
        mock_pyth::register<TEST_USDC>(&mut prices, test_scenario::ctx(&mut scenario));
        mock_pyth::register<TEST_SUI>(&mut prices, test_scenario::ctx(&mut scenario));

        lending_market::add_reserve<LENDING_MARKET, TEST_USDC>(
            &owner_cap,
            &mut lending_market,
            mock_pyth::get_price_obj<TEST_USDC>(&prices),
            reserve_config::default_reserve_config(),
            mock_metadata::get<TEST_USDC>(&metadata),
            &clock,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::add_reserve<LENDING_MARKET, TEST_USDC>(
            &owner_cap,
            &mut lending_market,
            mock_pyth::get_price_obj<TEST_USDC>(&prices),
            reserve_config::default_reserve_config(),
            mock_metadata::get<TEST_USDC>(&metadata),
            &clock,
            test_scenario::ctx(&mut scenario)
        );

        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(metadata);
        test_scenario::end(scenario);
    }

    public struct State {
        clock: Clock,
        owner_cap: LendingMarketOwnerCap<LENDING_MARKET>,
        lending_market: LendingMarket<LENDING_MARKET>,
        prices: PriceState,
        type_to_index: Bag
    }

    public struct ReserveArgs has store {
        config: ReserveConfig,
        initial_deposit: u64
    }

    #[test_only]
    fun setup(mut reserve_args: Bag, scenario: &mut Scenario): State {
        use suilend::test_usdc::{TEST_USDC};
        use suilend::test_sui::{TEST_SUI};
        use suilend::reserve_config::{Self};
        use sui::test_utils::{Self};
        use suilend::mock_pyth::{Self};
        use suilend::mock_metadata::{Self};
        use std::type_name::{Self};


        let clock = clock::create_for_testing(test_scenario::ctx(scenario));
        let metadata = mock_metadata::init_metadata(test_scenario::ctx(scenario));

        let (owner_cap, mut lending_market) = create_lending_market<LENDING_MARKET>(
            test_scenario::ctx(scenario)
        );

        let mut prices = mock_pyth::init_state(test_scenario::ctx(scenario));
        mock_pyth::register<TEST_USDC>(&mut prices, test_scenario::ctx(scenario));
        mock_pyth::register<TEST_SUI>(&mut prices, test_scenario::ctx(scenario));

        let mut type_to_index = bag::new(test_scenario::ctx(scenario));
        bag::add(&mut type_to_index, type_name::get<TEST_USDC>(), 0);
        bag::add(&mut type_to_index, type_name::get<TEST_SUI>(), 1);

        lending_market::add_reserve<LENDING_MARKET, TEST_USDC>(
            &owner_cap,
            &mut lending_market,
            mock_pyth::get_price_obj<TEST_USDC>(&prices),
            reserve_config::default_reserve_config(),
            mock_metadata::get<TEST_USDC>(&metadata),
            &clock,
            test_scenario::ctx(scenario)
        );

        lending_market::add_reserve<LENDING_MARKET, TEST_SUI>(
            &owner_cap,
            &mut lending_market,
            mock_pyth::get_price_obj<TEST_SUI>(&prices),
            reserve_config::default_reserve_config(),
            mock_metadata::get<TEST_SUI>(&metadata),
            &clock,
            test_scenario::ctx(scenario)
        );

        if (bag::contains(&reserve_args, type_name::get<TEST_USDC>())) {
            let ReserveArgs { config, initial_deposit } = bag::remove(
                &mut reserve_args, 
                type_name::get<TEST_USDC>()
            );
            let coins = coin::mint_for_testing<TEST_USDC>(
                initial_deposit, 
                test_scenario::ctx(scenario)
            );

            let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
                &mut lending_market,
                0,
                &clock,
                coins,
                test_scenario::ctx(scenario)
            );

            lending_market::update_reserve_config<LENDING_MARKET, TEST_USDC>(
                &owner_cap,
                &mut lending_market,
                0,
                config
            );

            test_utils::destroy(ctokens);
        };
        if (bag::contains(&reserve_args, type_name::get<TEST_SUI>())) {
            let ReserveArgs { config, initial_deposit } = bag::remove(
                &mut reserve_args, 
                type_name::get<TEST_SUI>()
            );
            let coins = coin::mint_for_testing<TEST_SUI>(
                initial_deposit, 
                test_scenario::ctx(scenario)
            );

            let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_SUI>(
                &mut lending_market,
                1,
                &clock,
                coins,
                test_scenario::ctx(scenario)
            );

            lending_market::update_reserve_config<LENDING_MARKET, TEST_SUI>(
                &owner_cap,
                &mut lending_market,
                1,
                config
            );

            test_utils::destroy(ctokens);
        };

        test_utils::destroy(reserve_args);
        test_utils::destroy(metadata);

        return State {
            clock,
            owner_cap,
            lending_market,
            prices,
            type_to_index
        }
    }


    #[test]
    public fun test_deposit() {
        use sui::test_utils::{Self};
        use suilend::test_usdc::{TEST_USDC};
        use std::type_name::{Self};
        use suilend::reserve_config::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let State { clock, owner_cap, mut lending_market, prices, type_to_index } = setup({
            let mut bag = bag::new(test_scenario::ctx(&mut scenario));
            bag::add(
                &mut bag, 
                type_name::get<TEST_USDC>(), 
                ReserveArgs {
                    config: reserve_config::default_reserve_config(),
                    initial_deposit: 100 * 1_000_000
                }
            );

            bag
        }, &mut scenario);

        let obligation_owner_cap = lending_market::create_obligation(
            &mut lending_market,
            test_scenario::ctx(&mut scenario)
        );

        let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));

        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            coins,
            test_scenario::ctx(&mut scenario)
        );
        assert!(coin::value(&ctokens) == 100 * 1_000_000, 0);

        let usdc_reserve = lending_market::reserve<LENDING_MARKET, TEST_USDC>(&lending_market);
        assert!(reserve::available_amount<LENDING_MARKET>(usdc_reserve) == 200 * 1_000_000, 0);

        lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &obligation_owner_cap,
            &clock,
            ctokens,
            test_scenario::ctx(&mut scenario)
        );

        let obligation = lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap));
        assert!(obligation::deposited_ctoken_amount<LENDING_MARKET, TEST_USDC>(obligation) == 100 * 1_000_000, 0);

        test_utils::destroy(obligation_owner_cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    #[test]
    public fun test_redeem() {
        use sui::test_utils::{Self};
        use suilend::test_usdc::{TEST_USDC};
        use std::type_name::{Self};
        use suilend::reserve_config::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let State { clock, owner_cap, mut lending_market, prices, type_to_index } = setup({
            let mut bag = bag::new(test_scenario::ctx(&mut scenario));
            bag::add(
                &mut bag, 
                type_name::get<TEST_USDC>(), 
                ReserveArgs {
                    config: reserve_config::default_reserve_config(),
                    initial_deposit: 100 * 1_000_000
                }
            );

            bag
        }, &mut scenario);

        let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            coins,
            test_scenario::ctx(&mut scenario)
        );
        assert!(coin::value(&ctokens) == 100 * 1_000_000, 0);

        let usdc_reserve = lending_market::reserve<LENDING_MARKET, TEST_USDC>(&lending_market);
        let old_available_amount = reserve::available_amount<LENDING_MARKET>(usdc_reserve);

        let tokens = lending_market::redeem_ctokens_and_withdraw_liquidity<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            ctokens,
            option::none(),
            test_scenario::ctx(&mut scenario)
        );
        assert!(coin::value(&tokens) == 100 * 1_000_000, 0);

        let usdc_reserve = lending_market::reserve<LENDING_MARKET, TEST_USDC>(&lending_market);
        let new_available_amount = reserve::available_amount<LENDING_MARKET>(usdc_reserve);
        assert!(new_available_amount == old_available_amount - 100 * 1_000_000, 0);

        test_utils::destroy(tokens);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    #[test]
    public fun test_borrow_and_repay() {
        use sui::test_utils::{Self};
        use suilend::test_usdc::{TEST_USDC};
        use suilend::test_sui::{TEST_SUI};
        use suilend::mock_pyth::{Self};
        use suilend::reserve_config::{Self, default_reserve_config};

        use std::type_name::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
            let mut bag = bag::new(test_scenario::ctx(&mut scenario));
            bag::add(
                &mut bag, 
                type_name::get<TEST_USDC>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_open_ltv_pct(&mut builder, 50);
                        reserve_config::set_close_ltv_pct(&mut builder, 50);
                        reserve_config::set_max_close_ltv_pct(&mut builder, 50);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000
                }
            );
            bag::add(
                &mut bag, 
                type_name::get<TEST_SUI>(), 
                ReserveArgs {
                    config: {
                        let config = reserve_config::default_reserve_config();
                        let mut builder = reserve_config::from(
                            &config,
                            test_scenario::ctx(&mut scenario)
                        );

                        test_utils::destroy(config);

                        reserve_config::set_borrow_fee_bps(&mut builder, 10);
                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000_000
                }
            );

            bag
        }, &mut scenario);

        clock::set_for_testing(&mut clock, 1 * 1000);

        // set reserve parameters and prices
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

        // create obligation
        let obligation_owner_cap = lending_market::create_obligation(
            &mut lending_market,
            test_scenario::ctx(&mut scenario)
        );

        let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            coins,
            test_scenario::ctx(&mut scenario)
        );
        lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &obligation_owner_cap,
            &clock,
            ctokens,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            mock_pyth::get_price_obj<TEST_USDC>(&prices)
        );
        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            mock_pyth::get_price_obj<TEST_SUI>(&prices)
        );

        let mut sui = lending_market::borrow<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &obligation_owner_cap,
            &clock,
            1 * 1_000_000_000,
            test_scenario::ctx(&mut scenario)
        );

        assert!(coin::value(&sui) == 1 * 1_000_000_000, 0);

        // state checks
        let sui_reserve = lending_market::reserve<LENDING_MARKET, TEST_SUI>(&lending_market);
        assert!(reserve::borrowed_amount<LENDING_MARKET>(sui_reserve) == decimal::from(1_001_000_000), 0);

        let obligation = lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap));
        assert!(obligation::borrowed_amount<LENDING_MARKET, TEST_SUI>(obligation) == decimal::from(1_001_000_000), 0);

        lending_market::repay<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            lending_market::obligation_id(&obligation_owner_cap),
            &clock,
            &mut sui,
            test_scenario::ctx(&mut scenario)
        );

        assert!(coin::value(&sui) == 0, 0);
        test_utils::destroy(sui);

        let sui_reserve = lending_market::reserve<LENDING_MARKET, TEST_SUI>(&lending_market);
        assert!(reserve::borrowed_amount<LENDING_MARKET>(sui_reserve) == decimal::from(1_000_000), 0);

        let obligation = lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap));
        assert!(obligation::borrowed_amount<LENDING_MARKET, TEST_SUI>(obligation) == decimal::from(1_000_000), 0);

        let mut sui = coin::mint_for_testing<TEST_SUI>(1_000_000_000, test_scenario::ctx(&mut scenario));
        lending_market::repay<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            lending_market::obligation_id(&obligation_owner_cap),
            &clock,
            &mut sui,
            test_scenario::ctx(&mut scenario)
        );
        assert!(coin::value(&sui) == 1_000_000_000 - 1_000_000, 0);

        let sui_reserve = lending_market::reserve<LENDING_MARKET, TEST_SUI>(&lending_market);
        assert!(reserve::borrowed_amount<LENDING_MARKET>(sui_reserve) == decimal::from(0), 0);

        let obligation = lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap));
        assert!(obligation::borrowed_amount<LENDING_MARKET, TEST_SUI>(obligation) == decimal::from(0), 0);

        test_scenario::next_tx(&mut scenario, owner);

        lending_market::claim_fees<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            test_scenario::ctx(&mut scenario)
        );

        test_scenario::next_tx(&mut scenario, owner);

        let fees: Coin<TEST_SUI> = test_scenario::take_from_address(&scenario, lending_market::fee_receiver(&lending_market));
        assert!(coin::value(&fees) == 1_000_000, 0);

        test_utils::destroy(fees);

        test_utils::destroy(sui);
        test_utils::destroy(obligation_owner_cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    #[test]
    public fun test_withdraw() {
        use sui::test_utils::{Self};
        use suilend::test_usdc::{TEST_USDC};
        use suilend::test_sui::{TEST_SUI};
        use suilend::mock_pyth::{Self};
        use suilend::reserve_config::{Self, default_reserve_config};

        use std::type_name::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
            let mut bag = bag::new(test_scenario::ctx(&mut scenario));
            bag::add(
                &mut bag, 
                type_name::get<TEST_USDC>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_open_ltv_pct(&mut builder, 50);
                        reserve_config::set_close_ltv_pct(&mut builder, 50);
                        reserve_config::set_max_close_ltv_pct(&mut builder, 50);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000
                }
            );
            bag::add(
                &mut bag, 
                type_name::get<TEST_SUI>(), 
                ReserveArgs {
                    config: reserve_config::default_reserve_config(),
                    initial_deposit: 100 * 1_000_000_000
                }
            );

            bag
        }, &mut scenario);

        clock::set_for_testing(&mut clock, 1 * 1000);

        // set reserve parameters and prices
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

        // create obligation
        let obligation_owner_cap = lending_market::create_obligation(
            &mut lending_market,
            test_scenario::ctx(&mut scenario)
        );

        let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            coins,
            test_scenario::ctx(&mut scenario)
        );
        lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &obligation_owner_cap,
            &clock,
            ctokens,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            mock_pyth::get_price_obj<TEST_USDC>(&prices)
        );
        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            mock_pyth::get_price_obj<TEST_SUI>(&prices)
        );

        let sui = lending_market::borrow<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &obligation_owner_cap,
            &clock,
            2_500_000_000,
            test_scenario::ctx(&mut scenario)
        );


        let obligation = lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap));
        let old_deposited_amount = obligation::deposited_ctoken_amount<LENDING_MARKET, TEST_USDC>(obligation);

        let usdc = lending_market::withdraw_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &obligation_owner_cap,
            &clock,
            50 * 1_000_000,
            test_scenario::ctx(&mut scenario)
        );

        let obligation = lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap));
        let deposited_amount = obligation::deposited_ctoken_amount<LENDING_MARKET, TEST_USDC>(obligation);

        assert!(coin::value(&usdc) == 50_000_000, 0);
        assert!(deposited_amount == old_deposited_amount - 50 * 1_000_000, 0);

        test_utils::destroy(sui);
        test_utils::destroy(usdc);
        test_utils::destroy(obligation_owner_cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    #[test]
    public fun test_liquidate() {
        use sui::test_utils::{Self};
        use suilend::test_usdc::{TEST_USDC};
        use suilend::test_sui::{TEST_SUI};
        use suilend::mock_pyth::{Self};
        use suilend::reserve_config::{Self, default_reserve_config};
        use suilend::decimal::{sub};

        use std::type_name::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
            let mut bag = bag::new(test_scenario::ctx(&mut scenario));
            bag::add(
                &mut bag, 
                type_name::get<TEST_USDC>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_open_ltv_pct(&mut builder, 50);
                        reserve_config::set_close_ltv_pct(&mut builder, 50);
                        reserve_config::set_max_close_ltv_pct(&mut builder, 50);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000
                }
            );
            bag::add(
                &mut bag, 
                type_name::get<TEST_SUI>(), 
                ReserveArgs {
                    config: reserve_config::default_reserve_config(),
                    initial_deposit: 100 * 1_000_000_000
                }
            );

            bag
        }, &mut scenario);

        clock::set_for_testing(&mut clock, 1 * 1000);

        // set reserve parameters and prices
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

        // create obligation
        let obligation_owner_cap = lending_market::create_obligation(
            &mut lending_market,
            test_scenario::ctx(&mut scenario)
        );

        let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            coins,
            test_scenario::ctx(&mut scenario)
        );
        lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &obligation_owner_cap,
            &clock,
            ctokens,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            mock_pyth::get_price_obj<TEST_USDC>(&prices)
        );
        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            mock_pyth::get_price_obj<TEST_SUI>(&prices)
        );

        let sui = lending_market::borrow<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &obligation_owner_cap,
            &clock,
            5 * 1_000_000_000,
            test_scenario::ctx(&mut scenario)
        );
        test_utils::destroy(sui);

        // set the open and close ltvs of the usdc reserve to 0
        let usdc_reserve = lending_market::reserve<LENDING_MARKET, TEST_USDC>(&lending_market);
        lending_market::update_reserve_config<LENDING_MARKET, TEST_USDC>(
            &owner_cap,
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            {
                let mut builder = reserve_config::from(
                    reserve::config(usdc_reserve), 
                    test_scenario::ctx(&mut scenario)
                );
                reserve_config::set_open_ltv_pct(&mut builder, 0);
                reserve_config::set_close_ltv_pct(&mut builder, 0);
                reserve_config::set_max_close_ltv_pct(&mut builder, 0);
                reserve_config::set_liquidation_bonus_bps(&mut builder, 400);
                reserve_config::set_max_liquidation_bonus_bps(&mut builder, 400);
                reserve_config::set_protocol_liquidation_fee_bps(&mut builder, 600);

                reserve_config::build(builder, test_scenario::ctx(&mut scenario))
            }
        );

        let obligation = lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap));

        let sui_reserve = lending_market::reserve<LENDING_MARKET, TEST_SUI>(&lending_market);
        let old_reserve_borrowed_amount = reserve::borrowed_amount<LENDING_MARKET>(sui_reserve);

        let old_deposited_amount = obligation::deposited_ctoken_amount<LENDING_MARKET, TEST_USDC>(obligation);
        let old_borrowed_amount = obligation::borrowed_amount<LENDING_MARKET, TEST_SUI>(obligation);

        // liquidate the obligation
        let mut sui = coin::mint_for_testing<TEST_SUI>(5 * 1_000_000_000, test_scenario::ctx(&mut scenario));
        let (usdc, exemption) = lending_market::liquidate<LENDING_MARKET, TEST_SUI, TEST_USDC>(
            &mut lending_market,
            lending_market::obligation_id(&obligation_owner_cap),
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            &mut sui,
            test_scenario::ctx(&mut scenario)
        );

        assert!(coin::value(&sui) == 4 * 1_000_000_000, 0);
        assert!(coin::value(&usdc) == 10 * 1_000_000 + 400_000, 0);
        assert!(exemption.amount() == 10 * 1_000_000 + 400_000, 0);

        let obligation = lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap));

        let sui_reserve = lending_market::reserve<LENDING_MARKET, TEST_SUI>(&lending_market);
        let reserve_borrowed_amount = reserve::borrowed_amount<LENDING_MARKET>(sui_reserve);

        let deposited_amount = obligation::deposited_ctoken_amount<LENDING_MARKET, TEST_USDC>(obligation);
        let borrowed_amount = obligation::borrowed_amount<LENDING_MARKET, TEST_SUI>(obligation);

        assert!(reserve_borrowed_amount == sub(old_reserve_borrowed_amount, decimal::from(1_000_000_000)), 0);
        assert!(borrowed_amount == sub(old_borrowed_amount, decimal::from(1_000_000_000)), 0);
        assert!(deposited_amount == old_deposited_amount - 11 * 1_000_000, 0);

        // check to see if we can do a full redeem even with rate limiter is disabled
        lending_market::update_rate_limiter_config<LENDING_MARKET>(
            &owner_cap,
            &mut lending_market,
            &clock,
            rate_limiter::new_config(1, 0) // disabled
        );

        let tokens = lending_market::redeem_ctokens_and_withdraw_liquidity<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            usdc,
            option::some(exemption),
            test_scenario::ctx(&mut scenario)
        );
        assert!(coin::value(&tokens) == 10 * 1_000_000 + 400_000, 0);

        // claim fees
        test_scenario::next_tx(&mut scenario, owner);
        lending_market::claim_fees<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            test_scenario::ctx(&mut scenario)
        );

        test_scenario::next_tx(&mut scenario, owner);
        let ctoken_fees: Coin<CToken<LENDING_MARKET, TEST_USDC>> = test_scenario::take_from_address(
            &scenario, 
            lending_market::fee_receiver(&lending_market)
        );
        assert!(coin::value(&ctoken_fees) == 600_000, 0);

        test_utils::destroy(ctoken_fees);
        test_utils::destroy(sui);
        test_utils::destroy(tokens);
        test_utils::destroy(obligation_owner_cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    const MILLISECONDS_IN_DAY: u64 = 86_400_000;

    #[test]
    fun test_liquidity_mining() {
        use sui::test_utils::{Self};
        use suilend::test_usdc::{TEST_USDC};
        use suilend::test_sui::{TEST_SUI};
        use suilend::reserve_config::{Self, default_reserve_config};
        use suilend::mock_pyth::{Self};

        use std::type_name::{Self};

        let owner = @0x26;

        let mut scenario = test_scenario::begin(owner);
        let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
            let mut bag = bag::new(test_scenario::ctx(&mut scenario));
            bag::add(
                &mut bag, 
                type_name::get<TEST_USDC>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_open_ltv_pct(&mut builder, 50);
                        reserve_config::set_close_ltv_pct(&mut builder, 50);
                        reserve_config::set_max_close_ltv_pct(&mut builder, 50);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000
                }
            );
            bag::add(
                &mut bag, 
                type_name::get<TEST_SUI>(), 
                ReserveArgs {
                    config: reserve_config::default_reserve_config(),
                    initial_deposit: 100 * 1_000_000_000
                }
            );

            bag
        }, &mut scenario);

        let usdc_rewards = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
        let sui_rewards = coin::mint_for_testing<TEST_SUI>(100 * 1_000_000_000, test_scenario::ctx(&mut scenario));

        lending_market::add_pool_reward<LENDING_MARKET, TEST_USDC>(
            &owner_cap,
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            true,
            usdc_rewards,
            0,
            10 * MILLISECONDS_IN_DAY,
            &clock,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::add_pool_reward<LENDING_MARKET, TEST_SUI>(
            &owner_cap,
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            true,
            sui_rewards,
            4 * MILLISECONDS_IN_DAY,
            14 * MILLISECONDS_IN_DAY,
            &clock,
            test_scenario::ctx(&mut scenario)
        );

        clock::set_for_testing(&mut clock, 1 * MILLISECONDS_IN_DAY);

        // create obligation
        let obligation_owner_cap = lending_market::create_obligation(
            &mut lending_market,
            test_scenario::ctx(&mut scenario)
        );

        let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            coins,
            test_scenario::ctx(&mut scenario)
        );
        lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &obligation_owner_cap,
            &clock,
            ctokens,
            test_scenario::ctx(&mut scenario)
        );


        // set reserve parameters and prices
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            mock_pyth::get_price_obj<TEST_USDC>(&prices)
        );
        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            mock_pyth::get_price_obj<TEST_SUI>(&prices)
        );
        let sui = lending_market::borrow<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &obligation_owner_cap,
            &clock,
            1_000_000_000,
            test_scenario::ctx(&mut scenario)
        );

        clock::set_for_testing(&mut clock, 9 * MILLISECONDS_IN_DAY);
        let claimed_usdc = lending_market::claim_rewards<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            &obligation_owner_cap,
            &clock,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            0,
            true,
            test_scenario::ctx(&mut scenario)
        );
        assert!(coin::value(&claimed_usdc) == 80 * 1_000_000, 0);

        // this fails because but rewards period is not over
        // claim_rewards_and_deposit<LENDING_MARKET, TEST_SUI>(
        //     &mut lending_market,
        //     obligation_owner_cap.obligation_id,
        //     &clock,
        //     *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
        //     1,
        //     true,
        //     *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
        //     test_scenario::ctx(&mut scenario)
        // );

        let remaining_sui_rewards = lending_market::cancel_pool_reward<LENDING_MARKET, TEST_SUI>(
            &owner_cap,
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            true,
            1,
            &clock,
            test_scenario::ctx(&mut scenario)
        );
        assert!(coin::value(&remaining_sui_rewards) == 50 * 1_000_000_000, 0);

        lending_market::claim_rewards_and_deposit<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            lending_market::obligation_id(&obligation_owner_cap),
            &clock,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            1,
            true,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            test_scenario::ctx(&mut scenario)
        );

        assert!(obligation::deposited_ctoken_amount<LENDING_MARKET, TEST_SUI>(
            lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap))
        ) == 49 * 1_000_000_000, 0);
        assert!(obligation::borrowed_amount<LENDING_MARKET, TEST_SUI>(
            lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap))
        ) == decimal::from(0), 0);

        let dust_sui_rewards = lending_market::close_pool_reward<LENDING_MARKET, TEST_SUI>(
            &owner_cap,
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            true,
            1,
            &clock,
            test_scenario::ctx(&mut scenario)
        );

        assert!(coin::value(&dust_sui_rewards) == 0, 0);

        test_utils::destroy(dust_sui_rewards);
        test_utils::destroy(remaining_sui_rewards);
        test_utils::destroy(sui);
        test_utils::destroy(owner_cap);
        test_utils::destroy(obligation_owner_cap);
        test_utils::destroy(claimed_usdc);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);

    }

    #[test]
    public fun test_forgive_debt() {
        use sui::test_utils::{Self};
        use suilend::test_usdc::{TEST_USDC};
        use suilend::test_sui::{TEST_SUI};
        use suilend::mock_pyth::{Self};
        use suilend::reserve_config::{Self, default_reserve_config};
        use suilend::decimal::{sub, eq};

        use std::type_name::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
            let mut bag = bag::new(test_scenario::ctx(&mut scenario));
            bag::add(
                &mut bag, 
                type_name::get<TEST_USDC>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_open_ltv_pct(&mut builder, 50);
                        reserve_config::set_close_ltv_pct(&mut builder, 50);
                        reserve_config::set_max_close_ltv_pct(&mut builder, 50);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000
                }
            );
            bag::add(
                &mut bag, 
                type_name::get<TEST_SUI>(), 
                ReserveArgs {
                    config: reserve_config::default_reserve_config(),
                    initial_deposit: 100 * 1_000_000_000
                }
            );

            bag
        }, &mut scenario);

        clock::set_for_testing(&mut clock, 1 * 1000);

        // set reserve parameters and prices
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

        // create obligation
        let obligation_owner_cap = lending_market::create_obligation(
            &mut lending_market,
            test_scenario::ctx(&mut scenario)
        );

        let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            coins,
            test_scenario::ctx(&mut scenario)
        );
        lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &obligation_owner_cap,
            &clock,
            ctokens,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            mock_pyth::get_price_obj<TEST_USDC>(&prices)
        );
        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            mock_pyth::get_price_obj<TEST_SUI>(&prices)
        );

        let sui = lending_market::borrow<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &obligation_owner_cap,
            &clock,
            5 * 1_000_000_000,
            test_scenario::ctx(&mut scenario)
        );
        test_utils::destroy(sui);

        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 2, &clock); // $10
        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            mock_pyth::get_price_obj<TEST_SUI>(&prices)
        );

        // liquidate the obligation
        let mut sui = coin::mint_for_testing<TEST_SUI>(1 * 1_000_000_000, test_scenario::ctx(&mut scenario));
        let (usdc, _exemption) = lending_market::liquidate<LENDING_MARKET, TEST_SUI, TEST_USDC>(
            &mut lending_market,
            lending_market::obligation_id(&obligation_owner_cap),
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            &mut sui,
            test_scenario::ctx(&mut scenario)
        );

        let obligation = lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap));
        let sui_reserve = lending_market::reserve<LENDING_MARKET, TEST_SUI>(&lending_market);
        let old_reserve_borrowed_amount = reserve::borrowed_amount<LENDING_MARKET>(sui_reserve);
        let old_borrowed_amount = obligation::borrowed_amount<LENDING_MARKET, TEST_SUI>(obligation);

        lending_market::forgive<LENDING_MARKET, TEST_SUI>(
            &owner_cap,
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            lending_market::obligation_id(&obligation_owner_cap),
            &clock,
            1_000_000_000,
        );

        let obligation = lending_market::obligation(&lending_market, lending_market::obligation_id(&obligation_owner_cap));
        let sui_reserve = lending_market::reserve<LENDING_MARKET, TEST_SUI>(&lending_market);
        let reserve_borrowed_amount = reserve::borrowed_amount<LENDING_MARKET>(sui_reserve);
        let borrowed_amount = obligation::borrowed_amount<LENDING_MARKET, TEST_SUI>(obligation);

        assert!(eq(sub(old_borrowed_amount, borrowed_amount), decimal::from(1_000_000_000)), 0);
        assert!(eq(sub(old_reserve_borrowed_amount, reserve_borrowed_amount), decimal::from(1_000_000_000)), 0);

        test_utils::destroy(usdc);
        test_utils::destroy(sui);
        test_utils::destroy(obligation_owner_cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

     #[test]
    public fun test_max_borrow() {
        use sui::test_utils::{Self};
        use suilend::test_usdc::{TEST_USDC};
        use suilend::test_sui::{TEST_SUI};
        use suilend::mock_pyth::{Self};
        use suilend::reserve_config::{Self, default_reserve_config};

        use std::type_name::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
            let mut bag = bag::new(test_scenario::ctx(&mut scenario));
            bag::add(
                &mut bag, 
                type_name::get<TEST_USDC>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_open_ltv_pct(&mut builder, 50);
                        reserve_config::set_close_ltv_pct(&mut builder, 50);
                        reserve_config::set_max_close_ltv_pct(&mut builder, 50);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000
                }
            );
            bag::add(
                &mut bag, 
                type_name::get<TEST_SUI>(), 
                ReserveArgs {
                    config: {
                        let config = reserve_config::default_reserve_config();
                        let mut builder = reserve_config::from(
                            &config,
                            test_scenario::ctx(&mut scenario)
                        );

                        test_utils::destroy(config);

                        reserve_config::set_borrow_fee_bps(&mut builder, 10);
                        // reserve_config::set_borrow_limit(&mut builder, 4 * 1_000_000_000);
                        // reserve_config::set_borrow_limit_usd(&mut builder, 20);
                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000_000
                }
            );

            bag
        }, &mut scenario);

        clock::set_for_testing(&mut clock, 1 * 1000);

        // set reserve parameters and prices
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

        // create obligation
        let obligation_owner_cap = lending_market::create_obligation(
            &mut lending_market,
            test_scenario::ctx(&mut scenario)
        );

        let coins = coin::mint_for_testing<TEST_USDC>(100 * 1_000_000, test_scenario::ctx(&mut scenario));
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            coins,
            test_scenario::ctx(&mut scenario)
        );
        lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &obligation_owner_cap,
            &clock,
            ctokens,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            mock_pyth::get_price_obj<TEST_USDC>(&prices)
        );
        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            mock_pyth::get_price_obj<TEST_SUI>(&prices)
        );

        let sui = lending_market::borrow<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &obligation_owner_cap,
            &clock,
            U64_MAX,
            test_scenario::ctx(&mut scenario)
        );

        assert!(coin::value(&sui) == 4_995_004_995, 0);

        test_utils::destroy(sui);
        test_utils::destroy(obligation_owner_cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    #[test]
    public fun test_max_withdraw() {
        use sui::test_utils::{Self};
        use suilend::test_usdc::{TEST_USDC};
        use suilend::test_sui::{TEST_SUI};
        use suilend::mock_pyth::{Self};
        use suilend::reserve_config::{Self, default_reserve_config};

        use std::type_name::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
            let mut bag = bag::new(test_scenario::ctx(&mut scenario));
            bag::add(
                &mut bag, 
                type_name::get<TEST_USDC>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_open_ltv_pct(&mut builder, 50);
                        reserve_config::set_close_ltv_pct(&mut builder, 50);
                        reserve_config::set_max_close_ltv_pct(&mut builder, 50);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000
                }
            );
            bag::add(
                &mut bag, 
                type_name::get<TEST_SUI>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_borrow_weight_bps(&mut builder, 20_000);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000_000
                }
            );

            bag
        }, &mut scenario);

        clock::set_for_testing(&mut clock, 1 * 1000);

        // set reserve parameters and prices
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

        // create obligation
        let obligation_owner_cap = lending_market::create_obligation(
            &mut lending_market,
            test_scenario::ctx(&mut scenario)
        );

        let coins = coin::mint_for_testing<TEST_USDC>(200 * 1_000_000, test_scenario::ctx(&mut scenario));
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            coins,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &obligation_owner_cap,
            &clock,
            ctokens,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            mock_pyth::get_price_obj<TEST_USDC>(&prices)
        );
        lending_market::refresh_reserve_price<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &clock,
            mock_pyth::get_price_obj<TEST_SUI>(&prices)
        );

        let sui = lending_market::borrow<LENDING_MARKET, TEST_SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_SUI>()),
            &obligation_owner_cap,
            &clock,
            2_500_000_000,
            test_scenario::ctx(&mut scenario)
        );

        lending_market::update_rate_limiter_config<LENDING_MARKET>(
            &owner_cap,
            &mut lending_market,
            &clock,
            rate_limiter::new_config(1, 10) // disabled
        );

        let cusdc = lending_market::withdraw_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &obligation_owner_cap,
            &clock,
            U64_MAX,
            test_scenario::ctx(&mut scenario)
        );
        let usdc = lending_market::redeem_ctokens_and_withdraw_liquidity<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            cusdc,
            option::none(),
            test_scenario::ctx(&mut scenario)
        );

        assert!(coin::value(&usdc) == 10 * 1_000_000, 0);

        test_utils::destroy(sui);
        test_utils::destroy(usdc);
        test_utils::destroy(obligation_owner_cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    #[test]
    public fun test_change_pyth_price_feed() {
        use sui::test_utils::{Self, assert_eq};
        use sui::test_scenario::ctx;
        use suilend::test_usdc::{TEST_USDC};
        use suilend::test_sui::{TEST_SUI};
        use suilend::mock_pyth::{Self};
        use suilend::reserve_config::{Self, default_reserve_config};

        use std::type_name::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
            let mut bag = bag::new(test_scenario::ctx(&mut scenario));
            bag::add(
                &mut bag, 
                type_name::get<TEST_USDC>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_open_ltv_pct(&mut builder, 50);
                        reserve_config::set_close_ltv_pct(&mut builder, 50);
                        reserve_config::set_max_close_ltv_pct(&mut builder, 50);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000
                }
            );
            bag::add(
                &mut bag, 
                type_name::get<TEST_SUI>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_borrow_weight_bps(&mut builder, 20_000);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000_000
                }
            );

            bag
        }, &mut scenario);

        clock::set_for_testing(&mut clock, 1 * 1000);

        // change the price feed as admin
        let new_price_info_obj = mock_pyth::new_price_info_obj(3_u8, ctx(&mut scenario));

        let array_idx = *bag::borrow(&type_to_index, type_name::get<TEST_USDC>());

        lending_market::change_reserve_price_feed<LENDING_MARKET, TEST_USDC>(
            &owner_cap,
            &mut lending_market,
            array_idx,
            &new_price_info_obj,
            &clock,
        );

        // TODO: assert changes
        let reserve_ref = lending_market::reserve<LENDING_MARKET, TEST_USDC>(&lending_market);
        let price_id = pyth::price_info::get_price_identifier(
            &pyth::price_info::get_price_info_from_price_info_object(&new_price_info_obj)
        );

        assert_eq(*reserve::price_identifier(reserve_ref), price_id);

        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_utils::destroy(new_price_info_obj);
        test_scenario::end(scenario);
    }
    
    #[test]
    public fun test_admin_new_obligation_cap() {
        use sui::test_utils::{Self};
        use suilend::test_usdc::{TEST_USDC};
        use suilend::test_sui::{TEST_SUI};
        use suilend::mock_pyth::{Self};
        use suilend::reserve_config::{Self, default_reserve_config};

        use std::type_name::{Self};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let State { mut clock, owner_cap, mut lending_market, mut prices, type_to_index } = setup({
            let mut bag = bag::new(test_scenario::ctx(&mut scenario));
            bag::add(
                &mut bag, 
                type_name::get<TEST_USDC>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_open_ltv_pct(&mut builder, 50);
                        reserve_config::set_close_ltv_pct(&mut builder, 50);
                        reserve_config::set_max_close_ltv_pct(&mut builder, 50);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000
                }
            );
            bag::add(
                &mut bag, 
                type_name::get<TEST_SUI>(), 
                ReserveArgs {
                    config: {
                        let config = default_reserve_config();
                        let mut builder = reserve_config::from(&config, test_scenario::ctx(&mut scenario));
                        reserve_config::set_borrow_weight_bps(&mut builder, 20_000);
                        sui::test_utils::destroy(config);

                        reserve_config::build(builder, test_scenario::ctx(&mut scenario))
                    },
                    initial_deposit: 100 * 1_000_000_000
                }
            );

            bag
        }, &mut scenario);

        clock::set_for_testing(&mut clock, 1 * 1000);

        // set reserve parameters and prices
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock); // $1
        mock_pyth::update_price<TEST_SUI>(&mut prices, 1, 1, &clock); // $10

        // create obligation
        let obligation_owner_cap = lending_market::create_obligation(
            &mut lending_market,
            test_scenario::ctx(&mut scenario)
        );

        let obligation_id = lending_market::obligation_id(&obligation_owner_cap);

        // Mock accidental burning of obligation cap
        transfer::public_transfer(obligation_owner_cap, @0x0);

        let obligation_owner_cap = lending_market::new_obligation_owner_cap(
            &owner_cap,
            &lending_market,
            obligation_id,
            test_scenario::ctx(&mut scenario)
        );

        assert!(lending_market::obligation_id(&obligation_owner_cap) == obligation_id, 0);

        test_utils::destroy(obligation_owner_cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }
}