// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AchievementTracker.sol";

/**
 * @title MultiplayerSnakesGameV2
 * @dev Enhanced multiplayer extension with achievement tracking and NFT holder benefits
 */
contract MultiplayerSnakesGameV2 {
    address public owner;
    AchievementTracker public achievementTracker;