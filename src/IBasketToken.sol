// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IBasketToken {
    function depositFee() external payable;
    function accruedOf(address who) external view returns (uint256);
    function claim(address holder) external returns (uint256);
}
