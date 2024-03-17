// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IBalanceOracle {
    function updateUserBalance(
        address _account,
        uint _amount
    ) external returns (uint);
}
