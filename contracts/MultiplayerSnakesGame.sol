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

    constructor() {
        owner = msg.sender;
    }

    /**
     * @dev Create a new multiplayer room
     */
    function createRoom(
        Difficulty _difficulty,
        uint256 _betAmount,
        uint256 _maxPlayers,
        PrizeModel _prizeModel
    ) external payable returns (uint256) {
        require(_betAmount > 0, "Bet amount must be > 0");
        require(_maxPlayers >= 2 && _maxPlayers <= MAX_PLAYERS_PER_ROOM, "Invalid max players");
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

        // Add host as first player
        room.players.push(msg.sender);
        room.joined[msg.sender] = true;

        activeRoomIds.push(roomId);
        
        emit RoomCreated(roomId, msg.sender, _difficulty, _betAmount);
        return roomId;
    }

    /**
     * @dev Join an existing room
     */
    function joinRoom(uint256 roomId) external payable roomExists(roomId) {
        Room storage room = rooms[roomId];
        require(room.status == RoomStatus.Waiting, "Room not accepting players");
        require(!room.joined[msg.sender], "Already joined");
        require(room.players.length < room.maxPlayers, "Room full");
        require(msg.value == room.betAmount, "Incorrect bet amount");

        room.players.push(msg.sender);
        room.joined[msg.sender] = true;
        room.prizePool += msg.value;

        emit PlayerJoined(roomId, msg.sender);

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

        // Refund bet
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
     * @dev Start the game (internal, called when room is full)
     */
    function _startGame(uint256 roomId) private {
        Room storage room = rooms[roomId];
        room.status = RoomStatus.Playing;
        room.startedAt = block.timestamp;

        // Generate deterministic board seed
        room.boardSeed = string(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            roomId,
            room.players.length
        ));

        // Remove from active rooms when game starts
        _removeFromActiveRooms(roomId);