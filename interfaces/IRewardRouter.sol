// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IRewardRouter {
    function feeUsdcTracker() external view returns (address);

    function stakedUsdcTracker() external view returns (address);

    function oracleCallback(address _account, uint _id, uint _amount) external;
}
