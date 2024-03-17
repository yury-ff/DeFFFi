// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./libraries/SafeMath.sol";
import "./libraries/IERC20.sol";
import "./libraries/IERC20Metadata.sol";
import "./libraries/SafeERC20.sol";
import "./libraries/ReentrancyGuard.sol";

import "./interfaces/IRewardDistributor.sol";
import "./interfaces/IRewardTracker.sol";
import "./access/Ownable.sol";

contract StableCoinRewardTracker is
    IERC20,
    IERC20Metadata,
    ReentrancyGuard,
    Ownable
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant PRECISION = 1e30;
    uint256 public FEE_IN_BASIS_POINTS = 50;
    uint256 public POST_FEE_AMOUNT =
        BASIS_POINTS_DIVISOR.sub(FEE_IN_BASIS_POINTS);

    bool public isInitialized;

    string public override name;
    string public override symbol;

    address public distributor;
    address private balanceOracle;

    mapping(address => bool) public isDepositToken;
    mapping(address => uint256) public totalDepositSupply;

    uint256 public override totalSupply;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    uint256 public cumulativeRewardPerToken;
    mapping(address => uint256) public stakedAmounts;
    mapping(address => uint256) public claimableReward;
    mapping(address => uint256) public previousCumulatedRewardPerToken;
    mapping(address => uint256) public cumulativeRewards;
    mapping(address => uint256) public averageStakedAmounts;

    bool public inPrivateTransferMode;
    bool public inPrivateStakingMode;
    bool public inPrivateClaimingMode;
    mapping(address => bool) public isHandler;

    event Claim(address receiver, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function initialize(
        address[] memory _depositTokens,
        address _distributor
    ) external onlyOwner {
        require(!isInitialized, "RewardTracker: already initialized");
        isInitialized = true;

        for (uint256 i = 0; i < _depositTokens.length; i++) {
            address depositToken = _depositTokens[i];
            isDepositToken[depositToken] = true;
        }

        distributor = _distributor;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setDepositToken(
        address _depositToken,
        bool _isDepositToken
    ) external onlyOwner {
        isDepositToken[_depositToken] = _isDepositToken;
    }

    function setInPrivateTransferMode(
        bool _inPrivateTransferMode
    ) external onlyOwner {
        inPrivateTransferMode = _inPrivateTransferMode;
    }

    function setInPrivateStakingMode(
        bool _inPrivateStakingMode
    ) external onlyOwner {
        inPrivateStakingMode = _inPrivateStakingMode;
    }

    function setInPrivateClaimingMode(
        bool _inPrivateClaimingMode
    ) external onlyOwner {
        inPrivateClaimingMode = _inPrivateClaimingMode;
    }

    function setHandler(address _handler, bool _isActive) external onlyOwner {
        isHandler[_handler] = _isActive;
    }

    function setFee(uint256 _newFEE) external onlyOwner {
        require(_newFEE <= 200, "Fee must be 2% or lower");
        FEE_IN_BASIS_POINTS = _newFEE;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external onlyOwner {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    // to update stakedAmounts daily if user make internal transfers
    function updateStakedAmounts(
        address[] memory _accounts,
        uint256[] memory _stakedAmounts
    ) external onlyOracle {
        for (uint256 i = 0; i < _accounts.length; i++) {
            stakedAmounts[_accounts[i]] = _stakedAmounts[i];
        }
    }

    // to update stakedAmount before withdrawal
    function updateStakedAmount(
        address _account,
        uint256 _stakedAmount
    ) external onlyOracle {
        stakedAmounts[_account] = _stakedAmount;
    }

    modifier onlyOracle() {
        require(
            msg.sender == balanceOracle,
            "You are not authorized to call this function."
        );
        _;
    }

    function setOracleAddress(address _balanceOracle) public onlyOwner {
        balanceOracle = _balanceOracle;
    }

    function balanceOf(
        address _account
    ) external view override returns (uint256) {
        return balances[_account];
    }

    function stake(
        address _depositToken,
        uint256 _amount
    ) external nonReentrant {
        if (inPrivateStakingMode) {
            revert("RewardTracker: action not enabled");
        }
        _stake(msg.sender, msg.sender, _depositToken, _amount);
    }

    function stakeForAccount(
        address _fundingAccount,
        address _account,
        address _depositToken,
        uint256 _amount
    ) external nonReentrant returns (uint256) {
        _validateHandler();
        uint256 postFeeAmount = _stake(
            _fundingAccount,
            _account,
            _depositToken,
            _amount
        );
        return postFeeAmount;
    }

    function unstake(
        address _depositToken,
        uint256 _amount
    ) external nonReentrant {
        if (inPrivateStakingMode) {
            revert("RewardTracker: action not enabled");
        }
        _unstake(msg.sender, _depositToken, _amount, msg.sender);
    }

    function unstakeForAccount(
        address _account,
        address _depositToken,
        uint256 _amount,
        address _receiver
    ) external nonReentrant {
        _validateHandler();
        _unstake(_account, _depositToken, _amount, _receiver);
    }

    function transfer(
        address _recipient,
        uint256 _amount
    ) external override returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function allowance(
        address _owner,
        address _spender
    ) external view override returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(
        address _spender,
        uint256 _amount
    ) external override returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) external override returns (bool) {
        if (isHandler[msg.sender]) {
            _transfer(_sender, _recipient, _amount);
            return true;
        }

        uint256 nextAllowance = allowances[_sender][msg.sender].sub(
            _amount,
            "RewardTracker: transfer amount exceeds allowance"
        );
        _approve(_sender, msg.sender, nextAllowance);
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function tokensPerInterval() external view returns (uint256) {
        return IRewardDistributor(distributor).tokensPerInterval();
    }

    function updateRewards() external nonReentrant {
        _updateRewards(address(0));
    }

    function claim(address _receiver) external nonReentrant returns (uint256) {
        if (inPrivateClaimingMode) {
            revert("RewardTracker: action not enabled");
        }
        return _claim(msg.sender, _receiver);
    }

    function claimForAccount(
        address _account,
        address _receiver
    ) external nonReentrant returns (uint256) {
        _validateHandler();
        return _claim(_account, _receiver);
    }

    function claimable(address _account) public view returns (uint256) {
        uint256 stakedAmount = stakedAmounts[_account];
        if (stakedAmount == 0) {
            return claimableReward[_account];
        }
        uint256 supply = totalSupply;
        uint256 pendingRewards = IRewardDistributor(distributor)
            .pendingRewards()
            .mul(PRECISION);
        uint256 nextCumulativeRewardPerToken = cumulativeRewardPerToken.add(
            pendingRewards.div(supply)
        );
        return
            claimableReward[_account].add(
                stakedAmount
                    .mul(
                        nextCumulativeRewardPerToken.sub(
                            previousCumulatedRewardPerToken[_account]
                        )
                    )
                    .div(PRECISION)
            );
    }

    function rewardToken() public view returns (address) {
        return IRewardDistributor(distributor).rewardToken();
    }

    function _claim(
        address _account,
        address _receiver
    ) private returns (uint256) {
        _updateRewards(_account);

        uint256 tokenAmount = claimableReward[_account];
        claimableReward[_account] = 0;

        if (tokenAmount > 0) {
            IERC20(rewardToken()).safeTransfer(_receiver, tokenAmount);
            emit Claim(_account, tokenAmount);
        }

        return tokenAmount;
    }

    function _mint(address _account, uint256 _amount) internal {
        require(
            _account != address(0),
            "RewardTracker: mint to the zero address"
        );

        totalSupply = totalSupply.add(_amount);
        balances[_account] = balances[_account].add(_amount);

        emit Transfer(address(0), _account, _amount);
    }

    function _burn(address _account, uint256 _amount) internal {
        require(
            _account != address(0),
            "RewardTracker: burn from the zero address"
        );

        balances[_account] = balances[_account].sub(
            _amount,
            "RewardTracker: burn amount exceeds balance"
        );
        totalSupply = totalSupply.sub(_amount);

        emit Transfer(_account, address(0), _amount);
    }

    function _transfer(
        address _sender,
        address _recipient,
        uint256 _amount
    ) private {
        require(
            _sender != address(0),
            "RewardTracker: transfer from the zero address"
        );
        require(
            _recipient != address(0),
            "RewardTracker: transfer to the zero address"
        );

        if (inPrivateTransferMode) {
            _validateHandler();
        }

        balances[_sender] = balances[_sender].sub(
            _amount,
            "RewardTracker: transfer amount exceeds balance"
        );
        balances[_recipient] = balances[_recipient].add(_amount);

        emit Transfer(_sender, _recipient, _amount);
    }

    function _approve(
        address _owner,
        address _spender,
        uint256 _amount
    ) private {
        require(
            _owner != address(0),
            "RewardTracker: approve from the zero address"
        );
        require(
            _spender != address(0),
            "RewardTracker: approve to the zero address"
        );

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "RewardTracker: forbidden");
    }

    function _stake(
        address _fundingAccount,
        address _account,
        address _depositToken,
        uint256 _amount
    ) private returns (uint256) {
        require(_amount > 0, "RewardTracker: invalid _amount");
        require(
            isDepositToken[_depositToken],
            "RewardTracker: invalid _depositToken"
        );

        IERC20(_depositToken).safeTransferFrom(
            _fundingAccount,
            address(this),
            _amount
        );

        _updateRewards(_account);

        uint256 postFeeAmount = _amount.mul(POST_FEE_AMOUNT).div(
            BASIS_POINTS_DIVISOR
        );

        stakedAmounts[_account] = stakedAmounts[_account].add(postFeeAmount);
        totalDepositSupply[_depositToken] = totalDepositSupply[_depositToken]
            .add(postFeeAmount);

        _mint(_account, postFeeAmount);
        return postFeeAmount;
    }

    function _unstake(
        address _account,
        address _depositToken,
        uint256 _amount,
        address _receiver
    ) private {
        require(_amount > 0, "RewardTracker: invalid _amount");
        require(
            isDepositToken[_depositToken],
            "RewardTracker: invalid _depositToken"
        );

        _updateRewards(_account);

        uint256 postFeeAmount = _amount.mul(POST_FEE_AMOUNT).div(
            BASIS_POINTS_DIVISOR
        );

        uint256 stakedAmount = stakedAmounts[_account];
        require(
            stakedAmounts[_account] >= _amount,
            "RewardTracker: _amount exceeds stakedAmount"
        );

        stakedAmounts[_account] = stakedAmount.sub(_amount);
        totalDepositSupply[_depositToken] = totalDepositSupply[_depositToken]
            .sub(_amount);

        _burn(_account, _amount);
        IERC20(_depositToken).safeTransfer(_receiver, postFeeAmount);
    }

    function _updateRewards(address _account) private {
        uint256 blockReward = IRewardDistributor(distributor).distribute();

        uint256 supply = totalSupply;
        uint256 _cumulativeRewardPerToken = cumulativeRewardPerToken;
        if (supply > 0 && blockReward > 0) {
            _cumulativeRewardPerToken = _cumulativeRewardPerToken.add(
                blockReward.mul(PRECISION).div(supply)
            );
            cumulativeRewardPerToken = _cumulativeRewardPerToken;
        }

        // cumulativeRewardPerToken can only increase
        // so if cumulativeRewardPerToken is zero, it means there are no rewards yet
        if (_cumulativeRewardPerToken == 0) {
            return;
        }

        if (_account != address(0)) {
            uint256 stakedAmount = stakedAmounts[_account];
            uint256 accountReward = stakedAmount
                .mul(
                    _cumulativeRewardPerToken.sub(
                        previousCumulatedRewardPerToken[_account]
                    )
                )
                .div(PRECISION);
            uint256 _claimableReward = claimableReward[_account].add(
                accountReward
            );

            claimableReward[_account] = _claimableReward;
            previousCumulatedRewardPerToken[
                _account
            ] = _cumulativeRewardPerToken;

            if (_claimableReward > 0 && stakedAmounts[_account] > 0) {
                uint256 nextCumulativeReward = cumulativeRewards[_account].add(
                    accountReward
                );

                averageStakedAmounts[_account] = averageStakedAmounts[_account]
                    .mul(cumulativeRewards[_account])
                    .div(nextCumulativeReward)
                    .add(
                        stakedAmount.mul(accountReward).div(
                            nextCumulativeReward
                        )
                    );

                cumulativeRewards[_account] = nextCumulativeReward;
            }
        }
    }
}
