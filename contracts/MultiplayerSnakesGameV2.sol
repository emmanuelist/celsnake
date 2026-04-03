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

    /**
     * @dev Join an existing room (with NFT holder benefits)
     */
    function joinRoom(uint256 roomId) external payable roomExists(roomId) {
        Room storage room = rooms[roomId];
        require(room.status == RoomStatus.Waiting, "Room not accepting players");
        require(!room.joined[msg.sender], "Already joined");
        require(room.players.length < room.maxPlayers, "Room full");
        require(msg.value == room.betAmount, "Incorrect bet amount");

        // Check exclusive tournament eligibility
        if (room.exclusiveTournament) {
            require(
                achievementTracker.isEligibleForExclusiveTournaments(msg.sender),
                "Gold+ achievement required for exclusive tournaments"
            );
        }

        // Calculate effective fee with discount
        uint256 discount = achievementTracker.getPlayerDiscount(msg.sender);
        uint256 effectiveFee = BASE_HOUSE_FEE_PERCENT > discount ? BASE_HOUSE_FEE_PERCENT - discount : 0;
        room.effectiveFee[msg.sender] = effectiveFee;

        room.players.push(msg.sender);
        room.joined[msg.sender] = true;
        room.prizePool += msg.value;

        // Record tournament participation
        if (room.exclusiveTournament) {
            achievementTracker.recordTournamentParticipation(msg.sender);
        }

        emit PlayerJoined(roomId, msg.sender, discount);

        // Auto-start if room is full
        if (room.players.length == room.maxPlayers) {
            _startGame(roomId);
        }
    }

    /**
     * @dev Leave a room before game starts
     */
    function leaveRoom(uint256 roomId) external roomExists(roomId) {
        Room storage room = rooms[roomId];
        require(room.status == RoomStatus.Waiting, "Cannot leave after game started");
        require(room.joined[msg.sender], "Not in room");

        uint256 betAmount = room.betAmount;
        room.prizePool -= betAmount;
        room.joined[msg.sender] = false;

        // Remove from players array
        for (uint256 i = 0; i < room.players.length; i++) {
            if (room.players[i] == msg.sender) {
                room.players[i] = room.players[room.players.length - 1];
                room.players.pop();
                break;
            }
        }

        payable(msg.sender).transfer(betAmount);
        emit PlayerLeft(roomId, msg.sender);

        // Cancel room if host leaves
        if (msg.sender == room.host && room.players.length > 0) {
            _cancelRoom(roomId);
        }
    }

    /**
     * @dev Start the game
     */
    function _startGame(uint256 roomId) private {
        Room storage room = rooms[roomId];
        room.status = RoomStatus.Playing;
        room.startedAt = block.timestamp;

        room.boardSeed = string(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            roomId,
            room.players.length
        ));

        _removeFromActiveRooms(roomId);
        emit GameStarted(roomId, room.boardSeed);
    }

    /**
     * @dev Mark player as eliminated
     */
    function eliminatePlayer(uint256 roomId, address player) external roomExists(roomId) {
        Room storage room = rooms[roomId];
        require(room.status == RoomStatus.Playing, "Game not in progress");
        require(room.joined[player], "Player not in room");
        require(!room.eliminated[player], "Already eliminated");

        room.eliminated[player] = true;
        emit PlayerEliminated(roomId, player);

        _checkGameEnd(roomId);
    }

    /**
     * @dev Mark player as finished with their score
     */
    function finishPlayer(uint256 roomId, uint256 score) external roomExists(roomId) {
        Room storage room = rooms[roomId];
        require(room.status == RoomStatus.Playing, "Game not in progress");
        require(room.joined[msg.sender], "Not in room");
        require(!room.eliminated[msg.sender], "Already eliminated");
        require(!room.finished[msg.sender], "Already finished");

        room.finished[msg.sender] = true;
        room.playerScores[msg.sender] = score;

        playerStats[msg.sender].totalGames++;

        emit PlayerFinished(roomId, msg.sender, score);

        _checkGameEnd(roomId);
    }

    /**
     * @dev Check if game should end and distribute prizes
     */
    function _checkGameEnd(uint256 roomId) private {
        Room storage room = rooms[roomId];

        bool allDone = true;
        for (uint256 i = 0; i < room.players.length; i++) {
            address player = room.players[i];
            if (!room.finished[player] && !room.eliminated[player]) {
                allDone = false;
                break;
            }
        }

        if (allDone) {
            _distributePrizes(roomId);
        }
    }

    /**
     * @dev Distribute prizes with NFT holder benefits
     */
    function _distributePrizes(uint256 roomId) private {
        Room storage room = rooms[roomId];
        require(room.status == RoomStatus.Playing, "Game not playing");

        room.status = RoomStatus.Finished;
        // Calculate average effective house fee
        uint256 totalFee = 0;
        for (uint256 i = 0; i < room.players.length; i++) {
            totalFee += room.effectiveFee[room.players[i]];
        }
        uint256 avgFee = totalFee / room.players.length;

        uint256 houseFee = (room.prizePool * avgFee) / 100;
        uint256 distributionPool = room.prizePool - houseFee;

        address[] memory winners;
        uint256[] memory prizes;