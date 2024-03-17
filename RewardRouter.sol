// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./libraries/SafeMath.sol";
import "./libraries/IERC20.sol";
import "./libraries/SafeERC20.sol";
import "./libraries/ReentrancyGuard.sol";
import "./libraries/Address.sol";

import "./interfaces/IRewardTracker.sol";
import "./interfaces/IVester.sol";
import "./interfaces/IStableCoinRewardTracker.sol";
import "./interfaces/IRewardRouter.sol";
import "./interfaces/IBalanceOracle.sol";
import "./interfaces/IMintable.sol";
import "./access/Ownable.sol";

contract RewardRouter is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    bool public isInitialized;

    address public DeFFFi;
    address public fidDeFFFi;
    address public usdc;
    address public feeDeFFFiTracker;
    address public feeUsdcTracker;
    address public usdcVester;
    address private balanceOracle;

    mapping(address => address) public pendingReceivers;
    mapping(uint256 => bool) updateBalanceRequests;

    event StakeDeFFFi(address account, address token, uint256 amount);
    event UnstakeDeFFFi(address account, address token, uint256 amount);

    event DepositUsdc(address account, uint256 amount);
    event WithdrawUsdc(address account, uint256 amount);

    function initialize(
        address _DeFFFi,
        address _fidDeFFFi,
        address _usdc,
        address _stakedDeFFFiTracker,
        address _feeDeFFFiTracker,
        address _feeUsdcTracker,
        address _usdcVester
    ) external onlyOwner {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;
        DeFFFi = _DeFFFi;
        fidDeFFFi = _fidDeFFFi;
        usdc = _usdc;
        stakedDeDeFFFiFiTracker = _stakedDeFFFiTracker;
        feeDeFFFiTracker = _feeDeFFFiTracker;
        feeUsdcTracker = _feeUsdcTracker;
        usdcVester = _usdcVester;
    }

    modifier onlyOracle() {
        require(
            msg.sender == balanceOracle,
            "You are not authorized to call this function."
        );
        _;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external onlyOwner {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function setOracleAddress(address _balanceOracle) public onlyOwner {
        balanceOracle = _balanceOracle;
    }

    function batchStakeDeFFFiForAccount(
        address[] memory _accounts,
        uint256[] memory _amounts
    ) external nonReentrant onlyOwner {
        address _DeFFFi = DeFFFi;
        for (uint256 i = 0; i < _accounts.length; i++) {
            _stakeDeFFFi(msg.sender, _accounts[i], _DeFFFi, _amounts[i]);
        }
    }

    function stakeDeFFFiForAccount(
        address _account,
        uint256 _amount
    ) external nonReentrant onlyOwner {
        _stakeDeFFFi(msg.sender, _account, DeFFFi, _amount);
    }

    function stakeDeFFFi(uint256 _amount) external nonReentrant {
        _stakeDeFFFi(msg.sender, msg.sender, DeFFFi, _amount);
    }

    function stakeFidDeFFFi(uint256 _amount) external nonReentrant {
        _stakeDeFFFi(msg.sender, msg.sender, fidDeFFFi, _amount);
    }

    function depositUsdc(uint256 _amount) external nonReentrant {
        _depositUsdc(msg.sender, msg.sender, _amount);
    }

    function unstakeDeFFFi(uint256 _amount) external nonReentrant {
        _unstakeDeFFFi(msg.sender, DeFFFi, _amount, true);
    }

    function unstakeFidDeFFFi(uint256 _amount) external nonReentrant {
        _unstakeDeFFFi(msg.sender, fidDeFFFi, _amount, true);
    }

    function withdrawUsdc(uint256 _amount) external nonReentrant {
        _initiateWithdrawUsdc(msg.sender, _amount);
    }

    function oracleCallback(
        address _account,
        uint _id,
        uint _amount
    ) external onlyOracle {
        require(
            updateBalanceRequests[_id],
            "This request is not in my pending list."
        );
        _withdrawUsdc(_account, _amount);
        delete updateBalanceRequests[_id];
    }

    function handleRewards(
        bool _shouldClaimDeFFFi,
        bool _shouldStakeDeFFFi,
        bool _shouldClaimFidDeFFFi,
        bool _shouldStakeFidDeFFFi,
        bool _shouldStakeMultiplierPoints,
        bool _shouldClaimUsdc,
        bool _shouldDepositUsdc
    ) external nonReentrant {
        address account = msg.sender;

        uint256 DeFFFiAmount = 0;
        

        if (_shouldStakeDeFFFi && DeFFFiAmount > 0) {
            _stakeDeFFFi(account, account, DeFFFi, DeFFFiAmount);
        }

        uint256 fidDeFFFiAmount = 0;
        if (_shouldClaimFidDeFFFi) {
            uint256 fidDeFFFiAmount0 = IRewardTracker(stakedDeFFFiTracker)
                .claimForAccount(account, account);
            
        }

        if (_shouldStakeFidDeFFFi && fidDeFFFiAmount > 0) {
            _stakeDeFFFi(account, account, fidDeFFFi, fidDeFFFiAmount);
        }

        
        uint256 usdcAmount = 0;
        if (_shouldClaimUsdc) {
            uint256 usdcAmount0 = IRewardTracker(feeDeFFFiTracker).claimForAccount(
                account,
                account
            );
            uint256 usdcAmount1 = IRewardTracker(feeUsdcTracker)
                .claimForAccount(account, account);
            usdcAmount = usdcAmount0.add(usdcAmount1);
        }
        if (_shouldDepositUsdc && usdcAmount > 0) {
            _depositUsdc(account, account, usdcAmount);
        }
    }

    function claim() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeDeFFFiTracker).claimForAccount(account, account);
        IRewardTracker(feeUsdcTracker).claimForAccount(account, account);

        IRewardTracker(stakedDeFFFiTracker).claimForAccount(account, account);
        
    }

    function claimFidDeFFFi() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(stakedDeFFFiTracker).claimForAccount(account, account);
        
    }

    function compound() external nonReentrant {
        _compound(msg.sender);
    }

    function compoundForAccount(
        address _account
    ) external nonReentrant onlyOwner {
        _compound(_account);
    }

    function batchCompoundForAccounts(
        address[] memory _accounts
    ) external nonReentrant onlyOwner {
        for (uint256 i = 0; i < _accounts.length; i++) {
            _compound(_accounts[i]);
        }
    }

    function _compound(address _account) private {
        _compoundDeFFFi(_account);
        _compoundUsdc(_account);
    }

    function _compoundDeFFFi(address _account) private {
        uint256 fidDeFFFiAmount = IRewardTracker(stakedDeFFFiTracker).claimForAccount(
            _account,
            _account
        );
        if (fidDeFFFiAmount > 0) {
            _stakeDeFFFi(_account, _account, fidDeFFFi, fidDeFFFiAmount);
        }

        
        
    }

    function _compoundUsdc(address _account) private {
        
        uint256 usdcFeeAmount = IStableCoinRewardTracker(feeUsdcTracker)
            .claimForAccount(_account, _account);
        if (usdcFeeAmount > 0) {
            _depositUsdc(_account, _account, usdcFeeAmount);
        }
    }

    function _depositUsdc(
        address _fundingAccount,
        address _account,
        uint256 _amount
    ) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        uint256 postFeeAmount = IStableCoinRewardTracker(feeUsdcTracker)
            .stakeForAccount(_account, _account, usdc, _amount);
        


        emit DepositUsdc(_account, _amount);
    }

    function _initiateWithdrawUsdc(address _account, uint256 _amount) private {
        uint256 id = IBalanceOracle(balanceOracle).updateUserBalance(
            _account,
            _amount
        );
        updateBalanceRequests[id] = true;
    }

    function _withdrawUsdc(address _account, uint256 _amount) private {
        
        IStableCoinRewardTracker(feeUsdcTracker).unstakeForAccount(
            _account,
            usdc,
            _amount,
            _account
        );

        emit WithdrawUsdc(_account, _amount);
    }

    function _stakeDeFFFi(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount
    ) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        IRewardTracker(stakedDeFFFiTracker).stakeForAccount(
            _fundingAccount,
            _account,
            _token,
            _amount
        );
        
       

        emit StakeDeFFFi(_account, _token, _amount);
    }

    function _unstakeDeFFFi(
        address _account,
        address _token,
        uint256 _amount,
        
    ) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        uint256 balance = IRewardTracker(stakedDeFFFiTracker).stakedAmounts(
            _account
        );

       
        
        IRewardTracker(stakedDeFFFiTracker).unstakeForAccount(
            _account,
            _token,
            _amount,
            _account
        );

        

        emit UnstakeDeFFFi(_account, _token, _amount);
    }
}
