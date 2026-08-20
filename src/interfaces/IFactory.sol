// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IFactory
/// @notice Interface for the constant-product pair factory.
interface IFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 allPairsLength);
    event FeeToUpdated(address indexed feeTo);
    event FeeToSetterUpdated(address indexed feeToSetter);
    event ProtocolFeeBpsUpdated(uint256 feeBps);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    /// @notice Protocol's share of the 0.30% swap fee, expressed in basis points (1e4 = 100%).
    function protocolFeeBps() external view returns (uint256);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint256 index) external view returns (address pair);
    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address feeTo) external;
    function setFeeToSetter(address feeToSetter) external;
    function setProtocolFeeBps(uint256 feeBps) external;
}
