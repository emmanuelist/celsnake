// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MultiplayerSnakesGame
 * @dev Multiplayer extension for Celo Snake game with turn-based mechanics
 * @notice Supports room-based gameplay with winner-takes-all or proportional distribution
 */

 contract MultiplayerSnakesGame {
    address public owner;
    uint256 public constant HOUSE_FEE_PERCENT = 5; // 5% house fee
    uint256 public constant MAX_PLAYERS_PER_ROOM = 4;
    uint256 public constant TURN_TIMEOUT = 60 seconds;

    enum RoomStatus { Waiting, Playing, Finished, Cancelled }
    enum PrizeModel { WinnerTakesAll, Proportional, Survival }
    enum Difficulty { Easy, Medium, Hard, Expert, Master }

    struct Room {
        uint256 id;
        address host;
        Difficulty difficulty;
        uint256 betAmount;
        uint256 maxPlayers;
        PrizeModel prizeModel;
        RoomStatus status;
        address[] players;
        mapping(address => bool) joined;
        mapping(address => uint256) playerScores;
        mapping(address => bool) eliminated;
        mapping(address => bool) finished;
        uint256 prizePool;
        uint256 createdAt;
        uint256 startedAt;
        string boardSeed; // For deterministic board generation
    }
    
    struct RoomInfo {
        uint256 id;
        address host;
        Difficulty difficulty;
        uint256 betAmount;
        uint256 maxPlayers;
        uint256 currentPlayers;
        PrizeModel prizeModel;
        RoomStatus status;
        uint256 prizePool;
    }

    struct PlayerStats {
        uint256 totalGames;
        uint256 wins;
        uint256 totalEarnings;
        string nickname;
    }

    // State variables
    uint256 public nextRoomId = 1;
    mapping(uint256 => Room) private rooms;
    uint256[] public activeRoomIds;
    mapping(address => PlayerStats) public playerStats;
    mapping(address => string) public nicknames;

    // Events
    event RoomCreated(uint256 indexed roomId, address indexed host, Difficulty difficulty, uint256 betAmount);
    event PlayerJoined(uint256 indexed roomId, address indexed player);