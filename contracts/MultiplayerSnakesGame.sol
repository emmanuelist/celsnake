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
        
        emit GameStarted(roomId, room.boardSeed);
    }
    
    /**
     * @dev Mark player as eliminated (called by game server or trusted oracle)
     */
    function eliminatePlayer(uint256 roomId, address player) external roomExists(roomId) {
        Room storage room = rooms[roomId];
        require(room.status == RoomStatus.Playing, "Game not in progress");
        require(room.joined[player], "Player not in room");
        require(!room.eliminated[player], "Already eliminated");
        
        // For MVP, allow any player to call this (will be oracle-only in production)
        room.eliminated[player] = true;
        
        emit PlayerEliminated(roomId, player);
        
        // Check if game should end
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
        
        // Check if game should end
        _checkGameEnd(roomId);
    }
    
    /**
     * @dev Check if game should end and distribute prizes
     */
    function _checkGameEnd(uint256 roomId) private {
        Room storage room = rooms[roomId];
        
        // Game ends when all players are either finished or eliminated
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
     * @dev Distribute prizes based on prize model
     */
    function _distributePrizes(uint256 roomId) private {
        Room storage room = rooms[roomId];
        require(room.status == RoomStatus.Playing, "Game not playing");
        
        room.status = RoomStatus.Finished;
        
        uint256 houseFee = (room.prizePool * HOUSE_FEE_PERCENT) / 100;
        uint256 distributionPool = room.prizePool - houseFee;
        
        address[] memory winners;
        uint256[] memory prizes;
        
        if (room.prizeModel == PrizeModel.WinnerTakesAll) {
            (winners, prizes) = _distributeWinnerTakesAll(roomId, distributionPool);
        } else if (room.prizeModel == PrizeModel.Proportional) {
            (winners, prizes) = _distributeProportional(roomId, distributionPool);
        } else if (room.prizeModel == PrizeModel.Survival) {
            (winners, prizes) = _distributeSurvival(roomId, distributionPool);
        }
        
        // Transfer prizes
        for (uint256 i = 0; i < winners.length; i++) {
            if (prizes[i] > 0) {
                playerStats[winners[i]].wins++;
                playerStats[winners[i]].totalEarnings += prizes[i];
                payable(winners[i]).transfer(prizes[i]);
            }
        }
        
        // Transfer house fee to owner
        payable(owner).transfer(houseFee);
        
        // Remove from active rooms
        _removeFromActiveRooms(roomId);
        
        emit GameFinished(roomId, winners, prizes);
    }

    /**
     * @dev Winner-takes-all distribution
     */
    function _distributeWinnerTakesAll(uint256 roomId, uint256 pool) 
        private 
        view 
        returns (address[] memory winners, uint256[] memory prizes)
    {
        Room storage room = rooms[roomId];

        // Find highest scorer who finished
        address winner;
        uint256 highestScore = 0;

        for (uint256 i = 0; i < room.players.length; i++) {
            address player = room.players[i];
            if (room.finished[player] && room.playerScores[player] > highestScore) {
                highestScore = room.playerScores[player];
                winner = player;
            }
        }

        if (winner != address(0)) {
            winners = new address[](1);
            prizes = new uint256[](1);
            winners[0] = winner;
            prizes[0] = pool;
        } else {
            winners = new address[](0);
            prizes = new uint256[](0);
        }
    }

    /**
     * @dev Proportional distribution (Top 3)
     */
    function _distributeProportional(uint256 roomId, uint256 pool) 
        private 
        view 
        returns (address[] memory winners, uint256[] memory prizes)
    {
        Room storage room = rooms[roomId];

        // Get all finished players sorted by score
        address[] memory finishedPlayers = new address[](room.players.length);
        uint256[] memory scores = new uint256[](room.players.length);
        uint256 finishedCount = 0;

        for (uint256 i = 0; i < room.players.length; i++) {
            if (room.finished[room.players[i]]) {
                finishedPlayers[finishedCount] = room.players[i];
                scores[finishedCount] = room.playerScores[room.players[i]];
                finishedCount++;
            }
        }

        // Sort by score (bubble sort for simplicity)
        for (uint256 i = 0; i < finishedCount; i++) {
            for (uint256 j = i + 1; j < finishedCount; j++) {
                if (scores[j] > scores[i]) {
                    (scores[i], scores[j]) = (scores[j], scores[i]);
                    (finishedPlayers[i], finishedPlayers[j]) = (finishedPlayers[j], finishedPlayers[i]);
                }
            }
        }

        // Distribute to top 3
        uint256 count = finishedCount > 3 ? 3 : finishedCount;
        winners = new address[](count);
        prizes = new uint256[](count);

        uint256[] memory percentages = new uint256[](3);
        percentages[0] = 60; // 1st: 60%
        percentages[1] = 25; // 2nd: 25%
        percentages[2] = 10; // 3rd: 10%

        for (uint256 i = 0; i < count; i++) {
            winners[i] = finishedPlayers[i];
            prizes[i] = (pool * percentages[i]) / 100;
        }
    }

    /**
     * @dev Survival bonus distribution
     */
    function _distributeSurvival(uint256 roomId, uint256 pool) 
        private 
        view 
        returns (address[] memory winners, uint256[] memory prizes) 
    {
        Room storage room = rooms[roomId];

        // Count survivors (finished without elimination)
        uint256 survivorCount = 0;
        for (uint256 i = 0; i < room.players.length; i++) {
            if (room.finished[room.players[i]]) {
                survivorCount++;
            }
        }

        if (survivorCount == 0) {
            return (new address[](0), new uint256[](0));
        }

        // Equal split among survivors
        winners = new address[](survivorCount);
        prizes = new uint256[](survivorCount);
        uint256 prizePerSurvivor = pool / survivorCount;
        
        uint256 idx = 0;
        for (uint256 i = 0; i < room.players.length; i++) {
            if (room.finished[room.players[i]]) {
                winners[idx] = room.players[i];
                prizes[idx] = prizePerSurvivor;
                idx++;
            }
        }
    }

    /**
     * @dev Cancel room and refund all players
     */
    function _cancelRoom(uint256 roomId) private {
        Room storage room = rooms[roomId];

    // Refund all players
        for (uint256 i = 0; i < room.players.length; i++) {
            address player = room.players[i];
            if (room.joined[player]) {
                payable(player).transfer(room.betAmount);
            }
        }