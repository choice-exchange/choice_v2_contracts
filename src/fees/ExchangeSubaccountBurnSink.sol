// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IBurnSink} from "../interfaces/IBurnSink.sol";
import {IExchangeModule} from "../interfaces/IExchangeModule.sol";
import {SubaccountLib} from "../libraries/SubaccountLib.sol";

/// @notice Burn sink candidate B (plan D8): the route Choice v1 has used for years.
///
/// `choice_send_to_auction` deposits into its own exchange subaccount and then
/// `ExternalTransfer`s to the auction subaccount `0x1111…1111`. Both calls exist on the
/// `0x65` precompile, so the same two steps work from the EVM side.
///
/// The cost of being faithful to v1 is a denom string. The precompile addresses funds by
/// bank denom, and nothing on chain maps an ERC20 address to one - the bank precompile's
/// `metadata(address)` returns name, symbol and decimals only. So the mapping is
/// administered: the owner (the timelock) registers a denom per currency before that
/// currency can be burnt through this sink.
contract ExchangeSubaccountBurnSink is IBurnSink, Ownable2Step {
    using CurrencyLibrary for Currency;

    IExchangeModule public constant EXCHANGE = IExchangeModule(0x0000000000000000000000000000000000000065);

    /// @notice Auction subaccount id: `0x1111…1111` at nonce 0.
    string public constant AUCTION_SUBACCOUNT = "0x1111111111111111111111111111111111111111000000000000000000000000";

    /// @notice Bank denom for each currency, e.g. "inj" or "erc20:0x…".
    mapping(Currency currency => string denom) public denomOf;

    error DenomNotRegistered(Currency currency);
    error DepositFailed();
    error ExternalTransferFailed();

    event DenomRegistered(Currency indexed currency, string denom);
    event Burnt(Currency indexed currency, uint256 amount);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Register the bank denom a currency is held as.
    /// @dev Must be set before the first harvest of that currency, or `burn` reverts and the
    /// harvest reverts with it - loudly, rather than silently keeping the burn share here.
    function setDenom(Currency currency, string calldata denom) external onlyOwner {
        denomOf[currency] = denom;
        emit DenomRegistered(currency, denom);
    }

    /// @inheritdoc IBurnSink
    /// @dev Permissionless for the same reason as the direct sink: the destination is a
    /// constant. Sweeps the balance rather than `amount` so a stray transfer cannot strand.
    function burn(Currency currency, uint256) external {
        string memory denom = denomOf[currency];
        if (bytes(denom).length == 0) revert DenomNotRegistered(currency);

        uint256 amount = currency.balanceOfSelf();
        if (amount == 0) return;

        // Step 1: bank balance -> this contract's own default subaccount.
        if (!EXCHANGE.deposit(address(this), SubaccountLib.defaultSubaccount(address(this)), denom, amount)) {
            revert DepositFailed();
        }
        // Step 2: our subaccount -> the auction subaccount. `externalTransfer` (not
        // `subaccountTransfer`) because source and destination have different owners.
        if (!EXCHANGE.externalTransfer(
                address(this), SubaccountLib.defaultSubaccount(address(this)), AUCTION_SUBACCOUNT, denom, amount
            )) {
            revert ExternalTransferFailed();
        }

        emit Burnt(currency, amount);
    }

    receive() external payable {}
}
