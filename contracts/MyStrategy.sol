// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@badger-finance/BaseStrategy.sol";
import {ICurveGauge} from "./interfaces/ICurveGauge.sol";
import {ICurvePool} from "./interfaces/ICurvePool.sol";
import {IUniswapRouterV2} from "./interfaces/IUniswapRouterV2.sol";
import {IERC20Upgradeable} from "./interfaces/IERC20Upgradeable.sol";

contract MyStrategy is BaseStrategy {
// address public want; // Inherited from BaseStrategy
    // address public lpComponent = 0x58e57cA18B7A47112b877E31929798Cd3D703b0f; // Token we provide liquidity with
    // address public reward = 0x1E4F97b9f9F913c46F1632781732927B9019C68b; // Token we farm and swap to want / lpComponent

    address public constant CRV = 0x1E4F97b9f9F913c46F1632781732927B9019C68b;

    // Used to swap rewards
    address public constant WFTM = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;
    address public constant USDT = 0x049d68029688eAbF473097a2fC38ef61633A3C7A;
    address public constant WETH = 0x74b23882a30290451A17c44f4F05243b6b58C76d;

    // We add liquidity here
    address public constant CURVE_POOL = 0x3a1659Ddcf2339Be3aeA159cA010979FB49155FF;

    // Swap via Sushi
    address public constant SUSHI_ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;

    // NOTE: Gauge can change, see setGauge
    address public gauge; // Set in initialize

    /// @dev Initialize the Strategy with security settings as well as tokens
    /// @notice Proxies will set any non constant variable you declare as default value
    /// @dev add any extra changeable variable at end of initializer as shown
    function initialize(address _vault, address[1] memory _wantConfig) public initializer {
        __BaseStrategy_init(_vault);
        want = _wantConfig[0];
        gauge = 0x00702BbDEaD24C40647f235F15971dB0867F6bdB;

        IERC20Upgradeable(want).approve(gauge, type(uint256).max);
        IERC20Upgradeable(USDT).approve(CURVE_POOL, type(uint256).max);
        IERC20Upgradeable(WETH).approve(CURVE_POOL, type(uint256).max);

        IERC20Upgradeable(CRV).approve(SUSHI_ROUTER, type(uint256).max);
        IERC20Upgradeable(WFTM).approve(SUSHI_ROUTER, type(uint256).max);
    }

    /// @dev Return the name of the strategy
    function getName() external pure override returns (string memory) {
        return "StrategyBadgerFantomCurveTricrypto";
    }

    /// @dev Return a list of protected tokens
    /// @notice It's very important all tokens that are meant to be in the strategy to be marked as protected
    /// @notice this provides security guarantees to the depositors they can't be sweeped away
    function getProtectedTokens() public view virtual override returns (address[] memory) {
        address[] memory protectedTokens = new address[](5);
        protectedTokens[0] = want;
        protectedTokens[1] = CRV;
        protectedTokens[2] = USDT;
        protectedTokens[3] = WFTM;
        protectedTokens[4] = gauge;
        return protectedTokens;
    }

    /// @dev Deposit `_amount` of want, investing it to earn yield
    function _deposit(uint256 _amount) internal override {
        ICurveGauge(gauge).deposit(_amount);
    }

    /// @dev Withdraw all funds, this is used for migrations, most of the time for emergency reasons
    function _withdrawAll() internal override {
        ICurveGauge(gauge).withdraw(balanceOfPool());
    }

    /// @dev Withdraw `_amount` of want, so that it can be sent to the vault / depositor
    /// @notice just unlock the funds and return the amount you could unlock
    function _withdrawSome(uint256 _amount) internal override returns (uint256) {
        if(_amount > balanceOfPool()) {
            _amount = balanceOfPool();
        }

        ICurveGauge(gauge).withdraw(_amount);
        return _amount;
    }

    /// @dev Does this function require `tend` to be called?
    function _isTendable() internal override pure returns (bool) {
        return true;
    }

    function _harvest() internal override returns (TokenAmount[] memory harvested) {
        // get balance before operation
        uint256 _before = IERC20Upgradeable(want).balanceOf(address(this));

        // figure out and claim our rewards
        ICurveGauge(gauge).claim_rewards();

        // get balance of rewards
        uint256 rewardAmount = IERC20Upgradeable(CRV).balanceOf(address(this));
        uint256 wftmAmount = IERC20Upgradeable(WFTM).balanceOf(address(this));

        // If no reward, then return zero amounts
        harvested = new TokenAmount[](2);
        if (rewardAmount == 0 && wftmAmount == 0) {
            harvested[0] = TokenAmount(CRV, 0);
            harvested[1] = TokenAmount(WFTM, 0);
            return harvested;
        }

        // Swap CRV to WETH
        if (rewardAmount > 0) {
            harvested[0] = TokenAmount(CRV, rewardAmount);

            address[] memory path = new address[](2);
            path[0] = CRV;
            path[1] = WETH;

            IUniswapRouterV2(SUSHI_ROUTER).swapExactTokensForTokens(rewardAmount, 0, path, address(this), now);
        } else {
            harvested[0] = TokenAmount(CRV, 0);
        }

        // Swap WFTM to USDT
        if (wftmAmount > 0) {
            harvested[1] = TokenAmount(WFTM, wftmAmount);

            address[] memory path = new address[](2);
            path[0] = WFTM;
            path[1] = USDT;

            IUniswapRouterV2(SUSHI_ROUTER).swapExactTokensForTokens(wftmAmount, 0, path, address(this), now);
        } else {
            harvested[1] = TokenAmount(WFTM, 0);
        }

        // Add liquidity to pool by depositing wBTC
        ICurvePool(CURVE_POOL).add_liquidity(
            [IERC20Upgradeable(USDT).balanceOf(address(this)), 0, IERC20Upgradeable(WETH).balanceOf(address(this))], 0
        );

        // for calculating the amount harvested
        uint256 _after = IERC20Upgradeable(want).balanceOf(address(this));

        // report the amount of want harvested to the sett
        _reportToVault(_after.sub(_before));

        // deposit to earn rewards
        _deposit(balanceOfWant());
        return harvested;
    }

    /// @dev Deposit any leftover want
    function _tend() internal override returns (TokenAmount[] memory tended) {
        uint256 amount = balanceOfWant();
        tended = new TokenAmount[](1);

        if(amount > 0) {
            _deposit(amount);
            tended[0] = TokenAmount(want, amount);
        } else {
            tended[0] = TokenAmount(want, 0);
        }
        return tended;
    }

    /// @dev Return the balance (in want) that the strategy has invested somewhere
    function balanceOfPool() public view override returns (uint256) {
        return IERC20Upgradeable(gauge).balanceOf(address(this));
    }

    /// @dev Return the balance of rewards that the strategy has accrued
    /// @notice Used for offChain APY and Harvest Health monitoring
    function balanceOfRewards() external view override returns (TokenAmount[] memory rewards) {
        rewards = new TokenAmount[](2);

        rewards[0] = TokenAmount(
            CRV,
            IERC20Upgradeable(CRV).balanceOf(address(this))
        );
        rewards[1] = TokenAmount(
            WFTM,
            IERC20Upgradeable(WFTM).balanceOf(address(this))
        );
        return rewards;
    }
}
