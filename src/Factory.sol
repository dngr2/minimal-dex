// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFactory} from "./interfaces/IFactory.sol";
import {Pair} from "./Pair.sol";

/// @title Factory
/// @notice Deploys and tracks constant-product pairs and holds the protocol-fee configuration.
/// @dev    Pairs are deployed deterministically via CREATE2 keyed on the sorted token addresses.
contract Factory is IFactory {
    /// @notice Upper bound on the protocol's share of the swap fee (50% of the 0.30% fee).
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 5_000;

    address public feeTo;
    address public feeToSetter;
    uint256 public protocolFeeBps;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();
    error Forbidden();
    error FeeBpsTooHigh();

    constructor(address _feeToSetter) {
        if (_feeToSetter == address(0)) revert ZeroAddress();
        feeToSetter = _feeToSetter;
    }

    /// @inheritdoc IFactory
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /// @inheritdoc IFactory
    /// @notice Creates the pair for (tokenA, tokenB); order-independent and unique.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        pair = address(new Pair{salt: salt}());
        Pair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /// @inheritdoc IFactory
    function setFeeTo(address _feeTo) external {
        if (msg.sender != feeToSetter) revert Forbidden();
        feeTo = _feeTo;
        emit FeeToUpdated(_feeTo);
    }

    /// @inheritdoc IFactory
    function setFeeToSetter(address _feeToSetter) external {
        if (msg.sender != feeToSetter) revert Forbidden();
        if (_feeToSetter == address(0)) revert ZeroAddress();
        feeToSetter = _feeToSetter;
        emit FeeToSetterUpdated(_feeToSetter);
    }

    /// @inheritdoc IFactory
    /// @notice Sets the protocol's share of the swap fee in basis points, capped at MAX_PROTOCOL_FEE_BPS.
    function setProtocolFeeBps(uint256 _feeBps) external {
        if (msg.sender != feeToSetter) revert Forbidden();
        if (_feeBps > MAX_PROTOCOL_FEE_BPS) revert FeeBpsTooHigh();
        protocolFeeBps = _feeBps;
        emit ProtocolFeeBpsUpdated(_feeBps);
    }
}
