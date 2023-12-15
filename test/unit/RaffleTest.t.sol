// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract RaffleTest is Test {
    event EnteredRaffle(address indexed player);
    event PickWinner(address indexed winner);

    Raffle raffle;
    HelperConfig helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    address link;

    address public PLAYER = makeAddr("player");
    uint256 public constant START_USER_BALANCE = 10 ether;

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.run();
        (entranceFee, interval, vrfCoordinator, gasLane, subscriptionId, callbackGasLimit, link,) =
            helperConfig.activeNetworkConfig();
        vm.deal(PLAYER, START_USER_BALANCE);
    }

    modifier raffleEnteredAndTimePassed() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    function test_Raffle_Initializes_In_Open_State() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function test_Raffle_Reverse_When_You_Dont_Pay_Enough() public {
        // Arrange
        vm.prank(PLAYER);
        // Act / Assert
        vm.expectRevert(Raffle.Raffle__NotEnoughtEthSent.selector);
        raffle.enterRaffle();
    }

    function test_Raffle_Records_Player_When_They_Enter() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        address playerRecorded = raffle.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function test_Emits_Event_On_Entrance() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(raffle));
        emit EnteredRaffle(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    function test_Cant_Enter_When_Raffle_Is_Calculating() public raffleEnteredAndTimePassed {
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    // Check Upkeep
    function test_Check_Upkeep_Returns_False_If_It_Has_No_Balance() public {
        // Arrange
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        // Act
        (bool upkeepNeeded,) = raffle.checkUpkeep("");

        // Assert
        assert(!upkeepNeeded);
    }

    function test_Check_Upkeep_Returns_False_If_Raffle_Not_Open() public raffleEnteredAndTimePassed {
        // Arrange

        raffle.performUpkeep("");
        Raffle.RaffleState raffleState = raffle.getRaffleState();

        // Act
        (bool upkeepNeeded,) = raffle.checkUpkeep("");

        // Assert
        assert(raffleState == Raffle.RaffleState.CALCULATING);
        assert(upkeepNeeded == false);
    }

    function test_Check_Upkeep_Returns_False_If_Enough_Time_Hasnt_Passed() public {
        // Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.warp(block.timestamp + interval - 1);
        vm.roll(block.number + 1);

        // Act
        (bool upkeepNeeded,) = raffle.checkUpkeep("");

        // Assert
        assert(upkeepNeeded == false);
    }

    function test_Check_Upkeep_Returns_True_When_Parameters_Are_Good() public raffleEnteredAndTimePassed {
        // Arrange

        // Act
        (bool upkeepNeeded,) = raffle.checkUpkeep("");

        // Assert
        assert(upkeepNeeded);
    }

    // Perform Upkeep
    function test_Perform_Upkeep_Can_Only_Run_If_Check_Upkeep_Is_True() public raffleEnteredAndTimePassed {
        // Arrange

        // Act
        raffle.performUpkeep("");
    }

    function test_Perform_Upkeep_Reverts_If_Check_Upkeep_Is_False() public {
        // Arrange
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        Raffle.RaffleState raffleState = raffle.getRaffleState();

        // Act / Assert
        vm.expectRevert(
            abi.encodeWithSelector(Raffle.Raffle__UpkeepNotNeeded.selector, currentBalance, numPlayers, raffleState)
        );

        raffle.performUpkeep("");
    }

    function test_Perform_Upkeep_Updates_Raffle_State_And_Emits_RequestId() public raffleEnteredAndTimePassed {
        // Act
        vm.recordLogs();
        raffle.performUpkeep(""); // Emit RequestID
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        Raffle.RaffleState raffleState = raffle.getRaffleState();

        assert(uint256(requestId) > 0);
        assert(raffleState == Raffle.RaffleState.CALCULATING);
    }

    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function test_Fulfill_Random_Words_Can_Only_Be_Called_After_Perform_Upkeep(uint256 randomRequestId)
        public
        raffleEnteredAndTimePassed
        skipFork
    {
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(randomRequestId, address(raffle));
    }

    function convertData(bytes32 data) internal pure returns (address) {
        return address(uint160(uint256(data)));
    }

    function test_Fulfill_Random_Words_Picks_A_Winner_Resets_And_Sends_Money()
        public
        raffleEnteredAndTimePassed
        skipFork
    {
        // Arrange
        uint256 additionalEntrants = 5;
        uint256 startingIndex = 1;
        for (uint256 i = startingIndex; i < startingIndex + additionalEntrants; i++) {
            address player = address(uint160(i));
            hoax(player, START_USER_BALANCE);
            raffle.enterRaffle{value: entranceFee}();
        }

        uint256 prize = entranceFee * (additionalEntrants + 1);

        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        uint256 previousTimeStamp = raffle.getLastTimeStamp();

        // pretend to be Chainlink VRF to get random number & pick winner
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(uint256(requestId), address(raffle));

        // Assert
        assert(uint256(raffle.getRaffleState()) == uint256(Raffle.RaffleState.OPEN));
        assert(raffle.getRecentWinner() != address(0));
        assert(raffle.getLengthOfPlayers() == 0);
        assert(previousTimeStamp < raffle.getLastTimeStamp());
        // Assert Events
        vm.prank(raffle.getRecentWinner());

        assert(raffle.getRecentWinner().balance == prize + START_USER_BALANCE - entranceFee);

        vm.recordLogs();
        emit PickWinner(raffle.getRecentWinner());
        Vm.Log[] memory pickWinnerEntries = vm.getRecordedLogs();
        // console.logBytes32(pickWinnerEntries[0].topics[1]);
        address winnerId = convertData(pickWinnerEntries[0].topics[1]);
        assert(winnerId == address(raffle.getRecentWinner()));
    }

    function test_Get_Entrance_Fee_Returns_Entrance_Fee() public view {
        assert(raffle.getEntranceFee() == entranceFee);
    }

    function test_Get_Raffle_State_Returns_Raffle_State() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function test_Get_Recent_Winner_Returns_Recent_Winner() public view {
        assert(raffle.getRecentWinner() == address(0));
    }

    function test_Get_Length_Of_Players_Returns_Length_Of_Players() public view {
        assert(raffle.getLengthOfPlayers() == 0);
    }

    function test_Get_Last_Time_Stamp_Returns_Last_Time_Stamp() public view {
        assert(raffle.getLastTimeStamp() == block.timestamp);
    }
}
