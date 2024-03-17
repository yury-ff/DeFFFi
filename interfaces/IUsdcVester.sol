// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IUsdcVester {
    function withdrawForAccounts(address[] memory _accounts) external;
}
