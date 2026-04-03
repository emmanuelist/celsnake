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
        mapping(address => uint256) effectiveFee; // NFT discount applied
        uint256 prizePool;
        uint256 createdAt;
        uint256 startedAt;
        string boardSeed;
        bool exclusiveTournament; // Gold+ holders only
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
        bool exclusiveTournament;
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
    event RoomCreated(uint256 indexed roomId, address indexed host, Difficulty difficulty, uint256 betAmount, bool exclusive);
    event PlayerJoined(uint256 indexed roomId, address indexed player, uint256 discountApplied);
    event PlayerLeft(uint256 indexed roomId, address indexed player);
    event GameStarted(uint256 indexed roomId, string boardSeed);
    event PlayerEliminated(uint256 indexed roomId, address indexed player);
    event PlayerFinished(uint256 indexed roomId, address indexed player, uint256 score);
    event GameFinished(uint256 indexed roomId, address[] winners, uint256[] prizes);
    event RoomCancelled(uint256 indexed roomId);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier roomExists(uint256 roomId) {
        require(roomId > 0 && roomId < nextRoomId, "Room does not exist");
        _;
    }

    constructor(address _achievementTracker) {
        owner = msg.sender;
        achievementTracker = AchievementTracker(_achievementTracker);
    }

    /**
     * @dev Create a new multiplayer room
     */
    function createRoom(
        Difficulty _difficulty,
        uint256 _betAmount,
        uint256 _maxPlayers,
        PrizeModel _prizeModel,
        bool _exclusiveTournament
    ) external payable returns (uint256) {
        require(_betAmount > 0, "Bet amount must be > 0");
        require(_maxPlayers >= 2 && _maxPlayers <= MAX_PLAYERS_PER_ROOM, "Invalid max players");

        // Check exclusive tournament eligibility
        if (_exclusiveTournament) {
            require(
                achievementTracker.isEligibleForExclusiveTournaments(msg.sender),
                "Gold+ achievement required for exclusive tournaments"
            );
        }

        // Calculate effective bet with discount
        uint256 discount = achievementTracker.getPlayerDiscount(msg.sender);
        uint256 effectiveFee = BASE_HOUSE_FEE_PERCENT > discount ? BASE_HOUSE_FEE_PERCENT - discount : 0;

        require(msg.value == _betAmount, "Incorrect bet amount");

        uint256 roomId = nextRoomId++;
        Room storage room = rooms[roomId];
        room.id = roomId;
        room.host = msg.sender;
        room.difficulty = _difficulty;
        room.betAmount = _betAmount;
        room.maxPlayers = _maxPlayers;
        room.prizeModel = _prizeModel;
        room.status = RoomStatus.Waiting;
        room.createdAt = block.timestamp;
        room.prizePool = msg.value;
        room.exclusiveTournament = _exclusiveTournament;
        room.effectiveFee[msg.sender] = effectiveFee;

        // Add host as first player
        room.players.push(msg.sender);
        room.joined[msg.sender] = true;

        activeRoomIds.push(roomId);

        // Record tournament participation
        if (_exclusiveTournament) {
            achievementTracker.recordTournamentParticipation(msg.sender);
        }

        emit RoomCreated(roomId, msg.sender, _difficulty, _betAmount, _exclusiveTournament);
        return roomId;
    }