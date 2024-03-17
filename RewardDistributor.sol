// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./libraries/SafeMath.sol";
import "./libraries/IERC20.sol";
import "./libraries/SafeERC20.sol";
import "./libraries/ReentrancyGuard.sol";
import "./libraries/Address.sol";

import "./interfaces/IRewardDistributor.sol";
import "./interfaces/IRewardTracker.sol";
import "./access/Ownable.sol";

contract RewardDistributor is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public rewardToken;
    uint256 public tokensPerInterval;
    uint256 public lastDistributionTime;
    address public rewardTracker;

    event Distribute(uint256 amount);
    event TokensPerIntervalChange(uint256 amount);

    constructor(address _rewardToken, address _rewardTracker) {
        rewardToken = _rewardToken;
        rewardTracker = _rewardTracker;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external onlyOwner {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function updateLastDistributionTime() external onlyOwner {
        lastDistributionTime = block.timestamp;
    }

    function setTokensPerInterval(uint256 _amount) external onlyOwner {
        require(
            lastDistributionTime != 0,
            "RewardDistributor: invalid lastDistributionTime"
        );
        IRewardTracker(rewardTracker).updateRewards();
        tokensPerInterval = _amount;
        emit TokensPerIntervalChange(_amount);
    }

    function pendingRewards() public view returns (uint256) {
        if (block.timestamp == lastDistributionTime) {
            return 0;
        }

        uint256 timeDiff = block.timestamp.sub(lastDistributionTime);
        return tokensPerInterval.mul(timeDiff);
    }

    function distribute() external returns (uint256) {
        require(
            msg.sender == rewardTracker,
            "RewardDistributor: invalid msg.sender"
        );
        uint256 amount = pendingRewards();
        if (amount == 0) {
            return 0;
        }

        lastDistributionTime = block.timestamp;

        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (amount > balance) {
            amount = balance;
        }

        IERC20(rewardToken).safeTransfer(msg.sender, amount);

        emit Distribute(amount);
        return amount;
    }
}
