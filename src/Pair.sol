// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFactory} from "./interfaces/IFactory.sol";
import {IPair} from "./interfaces/IPair.sol";
import {IFlashSwapCallee} from "./interfaces/IFlashSwapCallee.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";

/// @title Pair
/// @notice A constant-product (x*y=k) automated market maker for a single token pair.
///         The contract is itself the ERC20 liquidity-provider (LP) token for the pool.
/// @dev    Clean-room implementation of the well-known constant-product design.
///         Swap accounting uses balance deltas, making it safe for fee-on-transfer tokens.
///         A 0.30% fee is charged on every swap; a bounded protocol share of that fee
///         accrues to the factory's `feeTo` using the mint-on-liquidity-events (`kLast`) model.
contract Pair is IPair, ERC20Permit, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using UQ112x112 for uint224;

    /// @notice Minimum liquidity permanently locked on the first mint to prevent the
    ///         share-inflation (first-depositor) attack.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @dev OpenZeppelin's ERC20 forbids minting to address(0); the initial MINIMUM_LIQUIDITY
    ///      shares are instead sent to a burn address, permanently removing them from supply.
    address private constant BURN_ADDRESS = address(0xdEaD);

    /// @dev Basis-points denominator (1e4 == 100%).
    uint256 private constant BPS = 10_000;

    address public immutable factory;

    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    /// @notice Time-weighted cumulative price accumulators (UQ112x112), Uniswap-V2 style.
    /// @dev    price0CumulativeLast accumulates the price of token0 denominated in token1
    ///         (i.e. reserve1/reserve0) integrated over time; price1CumulativeLast is the inverse.
    ///         Each is incremented in `_update` by the elapsed-time-weighted price computed from the
    ///         reserves that held BEFORE the update, only when timeElapsed > 0. Downstream oracles
    ///         sample the difference of two checkpoints divided by the elapsed time to obtain a TWAP.
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    /// @notice reserve0 * reserve1 as of the most recent liquidity event; used for protocol-fee accounting.
    uint256 public kLast;

    error Forbidden();
    error AlreadyInitialized();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidTo();
    error KInvariantViolated();
    error Overflow();

    constructor() ERC20("Minimal DEX LP", "MDLP") ERC20Permit("Minimal DEX LP") {
        factory = msg.sender;
    }

    /// @dev Disambiguates the ERC-2612 nonce accessor inherited via both IPair (IERC20Permit) and ERC20Permit.
    function nonces(address owner) public view virtual override(IERC20Permit, ERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }

    /// @inheritdoc IPair
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /// @notice One-time initializer called by the factory immediately after deployment.
    function initialize(address _token0, address _token1) external {
        if (msg.sender != factory) revert Forbidden();
        if (token0 != address(0) || token1 != address(0)) revert AlreadyInitialized();
        token0 = _token0;
        token1 = _token1;
    }

    /// @dev Writes the reserves from the current balances, guards the uint112 range, and advances
    ///      the time-weighted cumulative-price accumulators using the reserves from BEFORE this
    ///      update (`_reserve0`/`_reserve1`). The accumulators only move when time has elapsed since
    ///      the last update and the pre-update reserves are both non-zero.
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();
        uint32 blockTimestamp = uint32(block.timestamp);
        unchecked {
            // Timestamp truncation and accumulator wrap-around are intentional (Uniswap-V2 semantics).
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
                price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
                price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
            }
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    /// @dev Mints the protocol's share of accrued fees to `feeTo` when enabled.
    ///      Protocol share = feeBps / 1e4 of the growth in sqrt(k) since the last liquidity event.
    ///      With feeBps ~= 1666 this reproduces Uniswap V2's canonical 1/6-of-fee split.
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IFactory(factory).feeTo();
        uint256 feeBps = IFactory(factory).protocolFeeBps();
        feeOn = feeTo != address(0) && feeBps > 0;
        uint256 _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(uint256(_reserve0) * uint256(_reserve1));
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    // liquidity minted so that feeTo ends up owning feeBps/1e4 of the fee-driven
                    // growth in pool value: m = phi*S*(rootK-rootKLast) / (rootK*(1-phi) + rootKLast*phi)
                    uint256 numerator = totalSupply() * (rootK - rootKLast) * feeBps;
                    uint256 denominator = rootK * (BPS - feeBps) + rootKLast * feeBps;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /// @inheritdoc IPair
    /// @notice Mints LP tokens to `to` for tokens already transferred into the pair.
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply(); // read after _mintFee mints its share
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(BURN_ADDRESS, MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY
        } else {
            liquidity = Math.min(amount0 * _totalSupply / _reserve0, amount1 * _totalSupply / _reserve1);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * uint256(reserve1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @inheritdoc IPair
    /// @notice Burns LP tokens held by the pair and returns the underlying reserves to `to`.
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply(); // read after _mintFee mints its share
        amount0 = liquidity * balance0 / _totalSupply;
        amount1 = liquidity * balance1 / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        _burn(address(this), liquidity);

        IERC20(_token0).safeTransfer(to, amount0);
        IERC20(_token1).safeTransfer(to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * uint256(reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @inheritdoc IPair
    /// @notice Swaps out `amount0Out`/`amount1Out` to `to`; the caller must have already sent the input.
    /// @dev    Backward-compatible no-data path (no flash-swap callback). Enforces the constant-product
    ///         invariant AFTER deducting the 0.30% fee.
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external nonReentrant {
        _swap(amount0Out, amount1Out, to, "");
    }

    /// @notice Flash-swap-capable variant: when `data` is non-empty the outputs are transferred
    ///         optimistically and `IFlashSwapCallee(to).flashSwapCall(msg.sender, ...)` is invoked
    ///         before the invariant is checked. The borrower must return the borrowed tokens plus the
    ///         0.30% fee (or supply the other side) so the post-callback balances still satisfy the
    ///         constant-product invariant.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external nonReentrant {
        _swap(amount0Out, amount1Out, to, data);
    }

    /// @dev    Shared swap core. `data.length > 0` triggers the flash-swap callback. Input amounts are
    ///         derived from balance deltas, so fee-on-transfer input tokens are accounted correctly, and
    ///         the k-invariant is enforced on the balances observed AFTER any callback returns.
    function _swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) private {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();

        address _token0 = token0;
        address _token1 = token1;
        if (to == _token0 || to == _token1) revert InvalidTo();

        if (amount0Out > 0) IERC20(_token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(_token1).safeTransfer(to, amount1Out);
        if (data.length > 0) IFlashSwapCallee(to).flashSwapCall(msg.sender, amount0Out, amount1Out, data);

        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        // 0.30% fee: require (balance - 0.003*in) product >= reserve product.
        uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
        if (balance0Adjusted * balance1Adjusted < uint256(_reserve0) * uint256(_reserve1) * (1000 * 1000)) {
            revert KInvariantViolated();
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @inheritdoc IPair
    /// @notice Forces any surplus balance above the reserves out to `to`.
    function skim(address to) external nonReentrant {
        address _token0 = token0;
        address _token1 = token1;
        IERC20(_token0).safeTransfer(to, IERC20(_token0).balanceOf(address(this)) - reserve0);
        IERC20(_token1).safeTransfer(to, IERC20(_token1).balanceOf(address(this)) - reserve1);
    }

    /// @inheritdoc IPair
    /// @notice Forces the reserves to match the current balances (absorbs donations).
    function sync() external nonReentrant {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
