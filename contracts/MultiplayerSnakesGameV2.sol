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

    uint256 public constant BASE_HOUSE_FEE_PERCENT = 5; // 5% base house fee
    uint256 public constant MAX_PLAYERS_PER_ROOM = 4;
    uint256 public constant TURN_TIMEOUT = 60 seconds;

    enum RoomStatus { Waiting, Playing, Finished, Cancelled }
    enum PrizeModel { WinnerTakesAll, Proportional, Survival }
    enum Difficulty { Easy, Medium, Hard, Expert, Master }