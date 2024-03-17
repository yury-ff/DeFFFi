// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./access/Ownable.sol";
import "./interfaces/IStableCoinRewardTracker.sol";
import "./interfaces/IRewardRouter.sol";
import "./interfaces/IUsdcVester.sol";

contract BalanceOracle is Ownable {
    address public feeUsdcTracker;
    address public stakedUsdcTracker;
    address public rewardRouter;
    address public usdcVester;

    uint private randNonce = 0;
    uint private modulus = 1000;
    uint public gasEthReceived;

    mapping(uint => bool) public pendingRequests;

    event UpdateUserBalanceEvent(address callerAddress, uint id, uint amount);
    event SetUserBalanceEvent(
        uint _userBalance,
        address _callerAddress,
        uint _amount
    );

    constructor(
        address _feeUsdcTracker,
        address _stakedUsdcTracker,
        address _rewardRouter,
        address _usdcVester
    ) {
        feeUsdcTracker = _feeUsdcTracker;
        stakedUsdcTracker = _stakedUsdcTracker;
        rewardRouter = _rewardRouter;
        usdcVester = _usdcVester;
    }

    function setRewardRouterAddress(address _rewardRouter) public onlyOwner {
        rewardRouter = _rewardRouter;
    }

    function updateUserBalance(
        address _account,
        uint _amount
    ) external returns (uint) {
        randNonce++;
        uint id = uint(
            keccak256(abi.encodePacked(block.timestamp, _account, randNonce))
        ) % modulus;
        pendingRequests[id] = true;
        emit UpdateUserBalanceEvent(_account, id, _amount);
        return id;
    }

    function updateAmountsAndUnstake(
        uint _stakedAmount,
        address _account,
        uint _id,
        uint _amount
    ) public onlyOwner {
        require(
            pendingRequests[_id],
            "This request is not in my pending list."
        );
        delete pendingRequests[_id];

        IStableCoinRewardTracker(feeUsdcTracker).updateStakedAmount(
            _account,
            _stakedAmount
        );
        IStableCoinRewardTracker(stakedUsdcTracker).updateStakedAmount(
            _account,
            _stakedAmount
        );
        IRewardRouter(rewardRouter).oracleCallback(_account, _id, _amount);

        emit SetUserBalanceEvent(_stakedAmount, _account, _amount);
    }

    function updateStakedAmounts(
        uint256[] memory _stakedAmounts,
        address[] memory _accounts,
        bool _shouldWithdrawVestingFF
    ) public onlyOwner {
        if (_shouldWithdrawVestingFF) {
            IUsdcVester(usdcVester).withdrawForAccounts(_accounts);
        }
        IStableCoinRewardTracker(feeUsdcTracker).updateStakedAmounts(
            _accounts,
            _stakedAmounts
        );
        IStableCoinRewardTracker(stakedUsdcTracker).updateStakedAmounts(
            _accounts,
            _stakedAmounts
        );
    }

    function depositGasEth() public payable {
        gasEthReceived += msg.value;
    }

    function withdrawGasEth() public onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }
}
