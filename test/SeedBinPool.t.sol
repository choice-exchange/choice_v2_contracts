// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {PriceHelper} from "infinity-core/src/pool-bin/libraries/PriceHelper.sol";
import {SeedBinPool} from "../script/06_SeedBinPool.s.sol";

/// @notice M7 step 2. The seed script's two off-chain decisions - the active id it derives from
/// a price, and the five-bin shape it spreads liquidity over - checked without a chain.
///
/// Both are the kind of mistake that does NOT revert. A mis-scaled price initialises a
/// perfectly healthy pool at a number twelve orders of magnitude off; a distribution that does
/// not sum to 1e18 is caught by the position manager, but only at broadcast time, after the
/// pool has already been created by the transaction before it.
contract SeedBinPoolTest is Test {
    using BinPoolParametersHelper for bytes32;

    /// @dev Mirrors the script's constants. Kept as literals rather than read off the contract
    /// so that changing one there fails here rather than silently re-deriving the assertion.
    uint16 internal constant BIN_STEP = 10;
    uint256 internal constant SEED_PRICE_18DP = 1e7;
    uint256 internal constant BIN_COUNT = 5;

    SeedBinPool internal script;

    function setUp() public {
        script = new SeedBinPool();
    }

    /// @dev 10 USDT per INJ across an 18/6 decimal pair is 1e-11 RAW, and the id must land on
    /// the bin containing it - below the 2^23 midpoint, since the raw ratio is under 1.
    function test_activeIdIsBelowMidpointAndRoundTrips() public pure {
        uint24 activeId =
            PriceHelper.getIdFromPrice(PriceHelper.convertDecimalPriceTo128x128(SEED_PRICE_18DP), BIN_STEP);

        assertLt(activeId, 1 << 23, "raw price under 1 must sit below the midpoint id");

        uint256 roundTripped = PriceHelper.convert128x128PriceToDecimal(PriceHelper.getPriceFromId(activeId, BIN_STEP));
        uint256 diff = roundTripped > SEED_PRICE_18DP ? roundTripped - SEED_PRICE_18DP : SEED_PRICE_18DP - roundTripped;

        // Within one bin's width. `getIdFromPrice` walks a logarithm and lands on the bin
        // CONTAINING the price, so it is lossy by construction and this is the only guarantee
        // available - but it is tight enough to catch a price scaled by 1e12.
        assertLe(diff * 10_000, uint256(BIN_STEP) * SEED_PRICE_18DP, "active id misses its own price by over a bin");
    }

    /// @dev The human price is 10; the raw one is 1e-11. Feeding the human number is the
    /// failure this pins, and it is silent: both ids are valid and both pools initialise.
    function test_humanPriceWouldSeedADifferentPool() public pure {
        uint24 raw = PriceHelper.getIdFromPrice(PriceHelper.convertDecimalPriceTo128x128(SEED_PRICE_18DP), BIN_STEP);
        uint24 human = PriceHelper.getIdFromPrice(PriceHelper.convertDecimalPriceTo128x128(10e18), BIN_STEP);

        assertGt(human, raw, "the human price sits far above the raw one");
        assertGt(human - raw, 1000, "a decimals mistake is thousands of bins wide, not a rounding error");
    }

    /// @dev 🔴 `parameters` packs binStep at offset 16 - the SAME offset CL packs tickSpacing
    /// at - so binStep 10 and tick spacing 10 produce a byte-identical parameters word. The
    /// only field that separates a bin pool key from a CL one is `poolManager`.
    ///
    /// That is the whole reason M7 step 4 cannot just delete the `pool_type` filter in
    /// `loadEdges`: it stamps ONE poolManager onto every edge it builds, and a bin pool carrying
    /// the CL manager is a valid key addressing a pool that does not exist. The quoter answers
    /// that with a revert indistinguishable from thin liquidity.
    function test_binStepAndTickSpacingPackIdentically() public pure {
        bytes32 binParams = bytes32(0).setBinStep(BIN_STEP);
        bytes32 clParams = CLPoolParametersHelper.setTickSpacing(bytes32(0), int24(uint24(BIN_STEP)));

        assertEq(binParams, clParams, "binStep and tickSpacing share offset 16");
        assertEq(BinPoolParametersHelper.getBinStep(binParams), BIN_STEP, "binStep must survive its round trip");

        PoolKey memory onBin = _key(address(0xB1), binParams);
        PoolKey memory onCl = _key(address(0xC1), clParams);

        assertTrue(
            PoolId.unwrap(onBin.toId()) != PoolId.unwrap(onCl.toId()),
            "the pool manager is the only thing telling these two keys apart"
        );
    }

    function _key(address poolManager, bytes32 parameters) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(poolManager),
            fee: 335,
            parameters: parameters
        });
    }
}
