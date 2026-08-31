// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BasketToken
/// @notice ERC-20 whose swap fees accrue to holders, pro-rata by balance at the moment
///         each fee lands. A share is frozen when it accrues: selling never claws back
///         what you already earned.
/// @dev Magnified-accumulator accounting. O(1) per holder, no iteration, no snapshots.
contract BasketToken {
    string public constant name = "Basket";
    string public constant symbol = "BASKET";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev Fixed-point scale for the accumulator. 1e18 of headroom over wei.
    uint256 private constant PRECISION = 1e18;

    /// @notice Cumulative wei distributed per token, scaled by PRECISION.
    uint256 public accPerShare;
    /// @notice Where each holder last synced against accPerShare.
    mapping(address => uint256) private _debt;
    /// @notice Wei already credited to a holder and awaiting claim.
    mapping(address => uint256) private _credited;

    /// @notice Wei that arrived while totalSupply was zero, held for the next deposit.
    uint256 public undistributed;

    address public immutable feeSource;
    /// @notice The only address allowed to pull a holder's accrued ETH for basket
    ///         settlement. Set at deploy, no setter.
    address public immutable basketVault;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event FeeReceived(uint256 amount);
    event Claimed(address indexed holder, address indexed caller, uint256 amount, uint256 tip);

    error NotFeeSource();
    error InsufficientBalance();
    error InsufficientAllowance();
    error NothingToClaim();
    error TransferFailed();
    error NotBasketVault();

    constructor(address _feeSource, address _basketVault, address mintTo, uint256 supply) {
        feeSource = _feeSource;
        basketVault = _basketVault;
        totalSupply = supply;
        balanceOf[mintTo] = supply;
        emit Transfer(address(0), mintTo, supply);
    }

    /* ------------------------------------------------------------- accounting */

    /// @dev Credit a holder everything owed at the current accumulator, then resync.
    ///      Must run before any balance change, using the OLD balance.
    function _sync(address who) private {
        if (who == address(0)) return;
        uint256 acc = accPerShare;
        _credited[who] += (balanceOf[who] * (acc - _debt[who])) / PRECISION;
        _debt[who] = acc;
    }

    /// @notice Wei a holder can claim right now.
    function accruedOf(address who) public view returns (uint256) {
        return _credited[who] + (balanceOf[who] * (accPerShare - _debt[who])) / PRECISION;
    }

    /// @notice Called by the hook with the swap fee. Splits across current holders.
    function depositFee() external payable {
        if (msg.sender != feeSource) revert NotFeeSource();
        uint256 amount = msg.value + undistributed;
        uint256 supply = totalSupply;
        if (supply == 0) {
            // Nobody to pay yet — hold it for the next deposit rather than burning it.
            undistributed = amount;
        } else {
            undistributed = 0;
            accPerShare += (amount * PRECISION) / supply;
        }
        emit FeeReceived(msg.value);
    }

    /// @notice Claim on behalf of any holder. The payout always goes to `holder`;
    ///         the caller takes `tipBips` of it as a gas incentive, so an indexer can
    ///         settle everyone and no share is ever stranded.
    uint256 public constant TIP_BIPS = 100; // 1%

    function claim(address holder) external returns (uint256 paid) {
        _sync(holder);
        uint256 owed = _credited[holder];
        if (owed == 0) revert NothingToClaim();
        _credited[holder] = 0;

        uint256 tip;
        if (msg.sender != holder) {
            tip = (owed * TIP_BIPS) / 10_000;
            owed -= tip;
        }
        paid = owed;

        (bool ok,) = holder.call{value: owed}("");
        if (!ok) revert TransferFailed();
        if (tip != 0) {
            (ok,) = msg.sender.call{value: tip}("");
            if (!ok) revert TransferFailed();
        }
        emit Claimed(holder, msg.sender, owed, tip);
    }

    /// @notice Pull a holder's accrued ETH to the vault, which owes them the basket.
    ///         Only the vault may call this; the ETH never reaches the caller.
    function claimToVault(address holder) external returns (uint256 owed) {
        if (msg.sender != basketVault) revert NotBasketVault();
        _sync(holder);
        owed = _credited[holder];
        if (owed == 0) return 0;
        _credited[holder] = 0;
        (bool ok,) = msg.sender.call{value: owed}("");
        if (!ok) revert TransferFailed();
    }

    /* ------------------------------------------------------------------ erc20 */

    function _move(address from, address to, uint256 value) private {
        // Settle both sides against their OLD balances before anything moves.
        _sync(from);
        _sync(to);
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - value;
            }
        }
        _move(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }
}
