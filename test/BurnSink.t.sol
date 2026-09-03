// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DirectTransferBurnSink} from "../src/fees/DirectTransferBurnSink.sol";
import {ExchangeSubaccountBurnSink} from "../src/fees/ExchangeSubaccountBurnSink.sol";
import {SubaccountLib} from "../src/libraries/SubaccountLib.sol";

/// @notice The burn leg is the one part of the fee model that cannot be verified by running
/// it: the `0x65` precompile does not exist under anvil, and a wrong subaccount string does
/// not revert - it quietly funds a subaccount nothing ever sweeps, and the money is simply
/// gone. So these tests pin the constants against the values read out of `injective-core`.
contract BurnSinkTest is Test {
    DirectTransferBurnSink internal direct;
    ExchangeSubaccountBurnSink internal viaExchange;
    MockERC20 internal token;

    address internal constant TIMELOCK = address(0x71E);

    /// @dev `exchange/types/common_utils.go`: AuctionSubaccountID. All 64 hex digits are 1;
    /// this is NOT an address followed by a zero nonce.
    string internal constant CHAIN_AUCTION_SUBACCOUNT =
        "0x1111111111111111111111111111111111111111111111111111111111111111";

    /// @dev ExchangeAuctionFeesAddress = the low 20 bytes of the above.
    address internal constant CHAIN_AUCTION_FEES_ADDRESS = 0x1111111111111111111111111111111111111111;

    function setUp() public {
        direct = new DirectTransferBurnSink();
        viaExchange = new ExchangeSubaccountBurnSink(TIMELOCK);
        token = new MockERC20("Token", "TKN", 18);
    }

    // ------------------------------------------------------------- pinned chain constants

    function test_auctionSubaccountIsThirtyTwoBytesOfOnes() public pure {
        assertEq(
            keccak256(bytes(CHAIN_AUCTION_SUBACCOUNT)),
            keccak256(bytes("0x1111111111111111111111111111111111111111111111111111111111111111"))
        );
        // 0x + 64 hex digits. A 20-byte address padded with a zero nonce is the same LENGTH,
        // which is exactly why the wrong value is easy to write and impossible to notice.
        assertEq(bytes(CHAIN_AUCTION_SUBACCOUNT).length, 66);
    }

    function test_exchangeSinkTargetsTheChainsAuctionSubaccount() public view {
        assertEq(
            keccak256(bytes(viaExchange.AUCTION_SUBACCOUNT())),
            keccak256(bytes(CHAIN_AUCTION_SUBACCOUNT)),
            "auction subaccount must match injective-core's AuctionSubaccountID"
        );
    }

    function test_directSinkTargetsTheChainsAuctionFeesAddress() public view {
        assertEq(direct.AUCTION(), CHAIN_AUCTION_FEES_ADDRESS);
    }

    /// @dev The whole reason v1 hops through nonce 1. A deposit into a DEFAULT subaccount is
    /// swept straight back to bank by `SetDepositOrSendToBank`, so the external transfer that
    /// follows would fail on an empty deposit. If this ever reads as a default subaccount the
    /// sink is silently broken, so assert the shape rather than the nonce.
    function test_exchangeSinkSourceIsNotADefaultSubaccount() public view {
        string memory source = SubaccountLib.subaccount(address(viaExchange), 1);
        bytes memory raw = bytes(source);

        bool allZeroNonce = true;
        // the 12-byte nonce is the last 24 hex chars of the 66-char string
        for (uint256 i = 42; i < 66; i++) {
            if (raw[i] != "0") allZeroNonce = false;
        }
        assertFalse(allZeroNonce, "source must not be the default subaccount: bank would sweep the deposit back");
    }

    function test_subaccountEncoding() public pure {
        address owner = 0x00000000000000000000000000000000DeaDBeef;
        assertEq(
            SubaccountLib.defaultSubaccount(owner),
            "0x00000000000000000000000000000000deadbeef000000000000000000000000",
            "default subaccount is address ++ 24 zeros, lowercase"
        );
        assertEq(
            SubaccountLib.subaccount(owner, 1),
            "0x00000000000000000000000000000000deadbeef000000000000000000000001",
            "nonce is a big-endian 12-byte suffix"
        );
    }

    // ------------------------------------------------------------- behaviour

    function test_directSinkSweepsItsWholeBalance() public {
        Currency currency = Currency.wrap(address(token));
        token.mint(address(direct), 1_000);

        // amount argument deliberately understates the balance: the sink sweeps what it holds,
        // so a transfer that arrived without a burn() call cannot be stranded.
        direct.burn(currency, 1);

        assertEq(token.balanceOf(CHAIN_AUCTION_FEES_ADDRESS), 1_000);
        assertEq(token.balanceOf(address(direct)), 0);
    }

    function test_directSinkIsANoopWhenEmpty() public {
        direct.burn(Currency.wrap(address(token)), 0);
        assertEq(token.balanceOf(CHAIN_AUCTION_FEES_ADDRESS), 0);
    }

    /// @dev An unregistered denom must revert, not silently keep the burn share. The revert
    /// propagates up through `harvest`, so the failure is loud at the first harvest of a new
    /// fee currency rather than a slowly growing balance nobody reads.
    function test_exchangeSinkRevertsOnAnUnregisteredDenom() public {
        Currency currency = Currency.wrap(address(token));
        token.mint(address(viaExchange), 1_000);

        vm.expectRevert(abi.encodeWithSelector(ExchangeSubaccountBurnSink.DenomNotRegistered.selector, currency));
        viaExchange.burn(currency, 1_000);
    }

    function test_onlyOwnerCanRegisterADenom() public {
        vm.expectRevert();
        viaExchange.setDenom(Currency.wrap(address(token)), "erc20:0x1234");

        vm.prank(TIMELOCK);
        viaExchange.setDenom(Currency.wrap(address(token)), "erc20:0x1234");
        assertEq(viaExchange.denomOf(Currency.wrap(address(token))), "erc20:0x1234");
    }
}
