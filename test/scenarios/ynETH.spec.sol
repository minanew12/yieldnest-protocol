// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import { IntegrationBaseTest } from "test/integration/IntegrationBaseTest.sol";
import { Invariants } from "test/scenarios/Invariants.sol";
import { IStakingNodesManager } from "src/interfaces/IStakingNodesManager.sol";
import { IStakingNode } from "src/interfaces/IStakingNode.sol";
import { BeaconChainProofs } from "lib/eigenlayer-contracts/src/contracts/libraries/BeaconChainProofs.sol";
import { IEigenPod } from "lib/eigenlayer-contracts/src/contracts/interfaces/IEigenPod.sol";
import { IEigenPodManager } from "lib/eigenlayer-contracts/src/contracts/interfaces/IEigenPodManager.sol";
import { IDelayedWithdrawalRouter } from "lib/eigenlayer-contracts/src/contracts/interfaces/IDelayedWithdrawalRouter.sol";
import { IRewardsDistributor } from "src/interfaces/IRewardsDistributor.sol";
import { ProofUtils } from "test/utils/ProofUtils.sol";

contract YnETHScenarioTest1 is IntegrationBaseTest {

	/**
		Scenario 1: Successful ETH Deposit and Share Minting 
		Objective: Test that a user can deposit ETH and receive 
		the correct amount of shares in return.
	*/

	address user1 = address(0x01);
	address user2 = address(0x02);
	address user3 = address(0x03);

	function test_ynETH_Scenario_1_Fuzz(uint256 random1, uint256 random2, uint256 random3) public {

		/**
			Users deposit random amounts
			- Check the total assets of ynETH
			- Check the share balance of each user
			- Check the total deposited in the pool
			- Check total supply of ynETH
		 */

		vm.assume(random1 > 0 && random1 < 100_000_000 ether);
		vm.assume(random2 > 0 && random2 < 100_000_000 ether);
		vm.assume(random3 > 0 && random3 < 100_000_000 ether);
		
		uint256 previousTotalDeposited;
		uint256 previousTotalShares;

		// user 1 deposits random1
		uint256 user1Amount = random1;
		vm.deal(user1, user1Amount);

		uint256 user1Shares = yneth.previewDeposit(user1Amount);
		yneth.depositETH{value: user1Amount}(user1);

		previousTotalDeposited = 0;
		previousTotalShares = 0;

		runInvariants(user1, previousTotalDeposited, previousTotalShares, user1Amount, user1Shares);

		// user 2 deposits random2
		uint256 user2Amount = random2;
		vm.deal(user2, user2Amount);

		uint256 user2Shares = yneth.previewDeposit(user2Amount);
		yneth.depositETH{value: user2Amount}(user2);

		previousTotalDeposited += user1Amount;
		previousTotalShares += user1Shares;

		runInvariants(user2, previousTotalDeposited, previousTotalShares, user2Amount, user2Shares);

		// user 3 deposits random3
		uint256 user3Amount = random3;
		vm.deal(user3, user3Amount);

		uint256 user3Shares = yneth.previewDeposit(user3Amount);
		yneth.depositETH{value: user3Amount}(user3);

		previousTotalDeposited += user2Amount;
		previousTotalShares += user2Shares;

		runInvariants(user3, previousTotalDeposited, previousTotalShares, user3Amount, user3Shares);
	}

	function runInvariants(address user, uint256 previousTotalDeposited, uint256 previousTotalShares, uint256 userAmount, uint256 userShares) public view {
		Invariants.totalDepositIntegrity(yneth.totalDepositedInPool(), previousTotalDeposited, userAmount);
		Invariants.totalAssetsIntegrity(yneth.totalAssets(), previousTotalDeposited, userAmount);
		Invariants.shareMintIntegrity(yneth.totalSupply(), previousTotalShares, userShares);
		Invariants.userSharesIntegrity(yneth.balanceOf(user), 0, userShares);
	}
}

contract YnETHScenarioTest2 is IntegrationBaseTest {

	/**
		Scenario 2: Deposit Paused 
		Objective: Ensure that deposits are correctly 
		paused and resumed, preventing or allowing ETH 
		deposits accordingly.
	 */

	address user1 = address(0x01);
	address user2 = address(0x02);

	// pause ynETH and try to deposit fail
	function test_ynETH_Scenario_2_Pause() public {

		vm.prank(actors.PAUSE_ADMIN);
	 	yneth.updateDepositsPaused(true);

	 	vm.deal(user1, 1 ether);
	 	vm.expectRevert(bytes4(keccak256(abi.encodePacked("Paused()"))));
	 	yneth.depositETH{value: 1 ether}(user1);
	}

	function test_ynETH_Scenario_2_Unpause() public {

	 	vm.startPrank(actors.PAUSE_ADMIN);
	 	yneth.updateDepositsPaused(true);
		assertTrue(yneth.depositsPaused());
		yneth.updateDepositsPaused(false);
		assertFalse(yneth.depositsPaused());
		vm.stopPrank();

		vm.deal(user1, 1 ether);
		vm.prank(user1);
		yneth.depositETH{value: 1 ether}(user1);
		assertEq(yneth.balanceOf(user1), 1 ether);
	}

	function test_ynETH_Scenario_2_Pause_Transfer(uint256 random1) public {

		vm.assume(random1 > 0 && random1 < 100_000_000 ether);
		
		uint256 amount = random1;
		vm.deal(user1, amount);
		vm.startPrank(user1);
		yneth.depositETH{value: amount}(user1);
		assertEq(yneth.balanceOf(user1), amount);

		// should fail when not on the pause whitelist
		yneth.approve(user2, amount);
		vm.expectRevert(bytes4(keccak256(abi.encodePacked("TransfersPaused()"))));
		yneth.transfer(user2, amount);
		vm.stopPrank();

		// should pass when on the pause whitelist
		vm.startPrank(actors.DEFAULT_SIGNER);
		vm.deal(actors.DEFAULT_SIGNER, amount);
		yneth.depositETH{value: amount}(actors.DEFAULT_SIGNER);

		uint256 transferEnabledEOABalance = yneth.balanceOf(actors.DEFAULT_SIGNER);
		yneth.transfer(user2, transferEnabledEOABalance);
		assertEq(yneth.balanceOf(user2), transferEnabledEOABalance);
	}

}

contract YnETHScenarioTest3 is IntegrationBaseTest {

	/**
		Scenario 3: Deposit and Withdraw ETH to Staking Nodes Manager
		Objective: Test that only the Staking Nodes Manager 
		can withdraw ETH from the contract.
	 */

	address user1 = address(0x01);
	
	function test_ynETH_Scenario_3_Deposit_Withdraw() public {

		// Deposit 32 ETH to ynETH and create a Staking Node with a Validator
		depositEth_and_createValidator();

		// Verify withdraw credentials
		// verifyEigenWithdrawCredentials(stakingNode);
	}

	function depositEth_and_createValidator() public returns (IStakingNode stakingNode, IStakingNodesManager.ValidatorData[] memory validatorData) {
		// 1. Create Validator and deposit 32 ETH

		//  Deposit 32 ETH to ynETH
		uint256 depositAmount = 32 ether;
		vm.deal(user1, depositAmount);
		vm.prank(user1);
		yneth.depositETH{value: depositAmount}(user1);

		// Staking Node Creator Role creates the staking nodes
		vm.prank(actors.STAKING_NODE_CREATOR);
		stakingNode = stakingNodesManager.createStakingNode();

		// Create a new Validator Data object
		validatorData = new IStakingNodesManager.ValidatorData[](1);
		validatorData[0] = IStakingNodesManager.ValidatorData({
            publicKey: ONE_PUBLIC_KEY,
            signature: ZERO_SIGNATURE,
            nodeId: 0,
            depositDataRoot: bytes32(0)
		});

		// Generate the deposit data root with withdrawal credentials
		bytes memory withdrawalCredentials = stakingNodesManager.getWithdrawalCredentials(validatorData[0].nodeId);
		validatorData[0].depositDataRoot = stakingNodesManager.generateDepositRoot(
			validatorData[0].publicKey, 
			validatorData[0].signature, 
			withdrawalCredentials,
			depositAmount
		);

		// checks the deposit Validator Data
        stakingNodesManager.validateNodes(validatorData);

		// get a deposit root from the ethereum deposit contract
        bytes32 depositRoot = depositContractEth2.get_deposit_root();

		// Validator Manager Role registers the validators
		vm.prank(actors.VALIDATOR_MANAGER);
		stakingNodesManager.registerValidators(depositRoot, validatorData);

		assertEq(address(yneth).balance, 0);

		return (stakingNode, validatorData);
	}

	function verifyEigenWithdrawCredentials(IStakingNode stakingNode) public {
        
        ProofUtils proofUtils = new ProofUtils();

		uint64 oracleTimestamp = uint64(block.timestamp);

		BeaconChainProofs.StateRootProof memory stateRootProof = proofUtils._getStateRootProof();

		uint40[] memory validatorIndexes = new uint40[](1);

		validatorIndexes[0] = uint40(proofUtils.getValidatorIndex());

        bytes[] memory validatorFieldsProofs = proofUtils._getValidatorFieldsProof();

		bytes32[][] memory validatorFields = new bytes32[][](1);
        validatorFields[0] = proofUtils.getValidatorFields();

		vm.prank(actors.STAKING_NODES_ADMIN);
		stakingNode.verifyWithdrawalCredentials(
            oracleTimestamp,
            stateRootProof,
            validatorIndexes,
            validatorFieldsProofs,
            validatorFields
        );

		IEigenPod eigenPod = IEigenPod(stakingNode.eigenPod());
		eigenPod.validatorStatus(0);
	}
}

event LogUint(string message, uint256 value);

contract YnETHScenarioTest8 is IntegrationBaseTest, YnETHScenarioTest3 {

	/**
		Scenario 8: Staking Rewards Distribution
		Objective: Test the distribution of staking rewards to a multisig.
	 */

	event Log(string message, uint256 value);
	event LogAddress(string message, address value);
	
	function test_ynETH_Scenario_8_Rewards_Distribution(uint256 randomAmount) public {
		vm.assume(randomAmount > 32 ether + 2 wei && randomAmount < 100_000_000 ether);

		// Deposit 32 ETH to ynETH and create a Staking Node with a Validator
		(IStakingNode stakingNode,) = depositEth_and_createValidator();

		// send concensus rewards to eigen pod
		uint256 amount = randomAmount;
        deal(address(this), randomAmount);

        // transfer eth to the eigen pod
        IEigenPod eigenPod = IEigenPod(stakingNode.eigenPod());
        (bool success,) = address(eigenPod).call{value: amount}(bytes(""));
        require(success, "transfer to eigen pod failed");
        
        // trigger withdraw before restaking succesfully
        vm.prank(actors.STAKING_NODES_ADMIN);
        stakingNode.withdrawNonBeaconChainETHBalanceWei();

		// // There should be a delayedWithdraw on the DelayedWithdrawalRouter
		IDelayedWithdrawalRouter withdrawalRouter = IDelayedWithdrawalRouter(chainAddresses.eigenlayer.DELAYED_WITHDRAWAL_ROUTER_ADDRESS);
		IDelayedWithdrawalRouter.DelayedWithdrawal[] memory delayedWithdrawals = withdrawalRouter.getUserDelayedWithdrawals(address(stakingNode));
		assertEq(delayedWithdrawals.length, 1);
		assertEq(delayedWithdrawals[0].amount, amount);

		// Because of the delay, the delayedWithdrawal should not be claimable yet
		IDelayedWithdrawalRouter.DelayedWithdrawal[] memory claimableDelayedWithdrawals = withdrawalRouter.getClaimableUserDelayedWithdrawals(address(stakingNode));
		assertEq(claimableDelayedWithdrawals.length, 0);

		// Move ahead in time to make the delayedWithdrawal claimable
		vm.roll(block.number + withdrawalRouter.withdrawalDelayBlocks() + 1);
		IDelayedWithdrawalRouter.DelayedWithdrawal[] memory claimableDelayedWithdrawalsWarp = withdrawalRouter.getClaimableUserDelayedWithdrawals(address(stakingNode));
		assertEq(claimableDelayedWithdrawalsWarp.length, 1);
		assertEq(claimableDelayedWithdrawalsWarp[0].amount, amount, "claimableDelayedWithdrawalsWarp[0].amount != 3 ether");

		withdrawalRouter.claimDelayedWithdrawals(address(stakingNode), type(uint256).max);

		// We can now claim the Rewards from delayedWithdrawal
		vm.prank(address(actors.STAKING_NODES_ADMIN));

		stakingNode.processWithdrawals(32 ether, address(stakingNode).balance);
        assertEq(address(stakingNode).balance, 0);

		// Get the rewards receiver addresses from the rewards distributor		
		IRewardsDistributor rewardsDistributor = IRewardsDistributor(stakingNodesManager.rewardsDistributor());
		address consensusLayerReceiver = address(rewardsDistributor.consensusLayerReceiver());

		uint256 concensusRewards = consensusLayerReceiver.balance;
        uint256 ynethBalance = address(yneth).balance;
		
		uint256 concensusRewardsExpected = amount - 32 ether;
		assertEq(concensusRewards, concensusRewardsExpected, "concensusRewards != concensusRewardsExpected");

        // validator principal should be returned to ynETH
		assertEq(ynethBalance, 32 ether, "yneth.balance != concensusRewardsExpected");
	}
}

contract YnETHScenarioTest10 is IntegrationBaseTest, YnETHScenarioTest3 {

	/**
		Scenario 10: Self-Destruct ETH Transfer Attack
		Objective: Ensure the system is not vulnerable to a self-destruct attack.
	 */

	function test_ynETH_Scenario_9_Self_Destruct_Attack() public {

		uint256 previousTotalDeposited = yneth.totalDepositedInPool();
		uint256 previousTotalShares = yneth.totalSupply();


		// Deposit 32 ETH to ynETH and create a Staking Node with a Validator		
		(IStakingNode stakingNode,) = depositEth_and_createValidator();

		// Amount of ether to send via self-destruct
		uint256 amountToSend = 1 ether;

		// Ensure the test contract has enough ether to send, user1 comes from Test3
		vm.deal(user1, amountToSend);

		// Address to send ether to - for example, the stakingNode or another address
		address payable target = payable(address(stakingNode)); // or any other target address

		// Create and send ether via self-destruct
		// The SelfDestructSender contract is created with the amountToSend and immediately self-destructs,
		// sending its balance to the target address.
		address(new SelfDestructSender{value: amountToSend}(target));
		
		log_balances(stakingNode);
		
		assertEq(address(yneth).balance, 0, "yneth.balance != 0");
		assertEq(address(stakingNode).balance, 1 ether, "stakingNode.balance !=  1 ether");
		assertEq(address(consensusLayerReceiver).balance, 0, "consensusLayerReceiver.balance != 0");
		assertEq(address(executionLayerReceiver).balance, 0, "executionLayerReceiver.balance != 0");

		vm.startPrank(actors.STAKING_NODES_ADMIN);
		withdraw_principal(stakingNode);
		stakingNode.processWithdrawals(32 ether, 33 ether + 1 wei);
		vm.stopPrank();

		log_balances(stakingNode);

		assertEq(address(yneth).balance, 32 ether, "yneth.balance != 32 ether");
		assertEq(address(stakingNode).balance, 0, "stakingNode.balance != 0");
		assertEq(address(consensusLayerReceiver).balance, 1 ether + 1 wei, "consensusLayerReceiver.balance != 0");
		assertEq(address(executionLayerReceiver).balance, 0, "executionLayerReceiver.balance != 0");

		uint256 userAmount = 32 ether;
		uint256 userShares = yneth.balanceOf(user1);

		runInvariants(
			user1, 
			previousTotalDeposited, 
			previousTotalShares,
			userAmount, 
			userShares
		);
	}

	function withdraw_principal(IStakingNode stakingNode) public {

		// send concensus rewards to eigen pod
		uint256 amount = 32 ether + 1 wei;
		IEigenPod eigenPod = IEigenPod(stakingNode.eigenPod());
		uint256 initialPodBalance = address(eigenPod).balance;
        
        vm.deal(actors.STAKING_NODES_ADMIN, 40 ether);
        (bool success,) = payable(address(eigenPod)).call{value: amount}("");
        require(success, "Failed to send rewards to EigenPod");

		assertEq(address(eigenPod).balance, initialPodBalance + amount, "eigenPod.balance != initialPodBalance + amount");

        // trigger withdraw before restaking succesfully
        stakingNode.withdrawNonBeaconChainETHBalanceWei();

		// There should be a delayedWithdraw on the DelayedWithdrawalRouter
		IDelayedWithdrawalRouter withdrawalRouter = IDelayedWithdrawalRouter(chainAddresses.eigenlayer.DELAYED_WITHDRAWAL_ROUTER_ADDRESS);
		IDelayedWithdrawalRouter.DelayedWithdrawal[] memory delayedWithdrawals = withdrawalRouter.getUserDelayedWithdrawals(address(stakingNode));
		assertEq(delayedWithdrawals.length, 1);
		assertEq(delayedWithdrawals[0].amount, amount);

		// Because of the delay, the delayedWithdrawal should not be claimable yet
		IDelayedWithdrawalRouter.DelayedWithdrawal[] memory claimableDelayedWithdrawals = withdrawalRouter.getClaimableUserDelayedWithdrawals(address(stakingNode));
		assertEq(claimableDelayedWithdrawals.length, 0, "claimableDelayedWithdrawals.length != 0");

		// Move ahead in time to make the delayedWithdrawal claimable
		vm.roll(block.number + withdrawalRouter.withdrawalDelayBlocks() + 1);
		IDelayedWithdrawalRouter.DelayedWithdrawal[] memory claimableDelayedWithdrawalsWarp = withdrawalRouter.getClaimableUserDelayedWithdrawals(address(stakingNode));
		assertEq(claimableDelayedWithdrawalsWarp.length, 1, "claimableDelayedWithdrawalsWarp.length != 1");
		assertEq(claimableDelayedWithdrawalsWarp[0].amount, amount, "claimableDelayedWithdrawalsWarp[0].amount != 3 ether");

		withdrawalRouter.claimDelayedWithdrawals(address(stakingNode), type(uint256).max);
	}

	function log_balances (IStakingNode stakingNode) public {
		emit LogUint("yneth.balance", address(yneth).balance);
		emit LogUint("stakingNode.balance", address(stakingNode).balance);
		emit LogUint("consensusReciever.balance", address(consensusLayerReceiver).balance);
		emit LogUint("executionReciever.balance", address(executionLayerReceiver).balance);
        emit LogUint("eigenPod.balance", address(IEigenPod(stakingNode.eigenPod())).balance);
	}

	function runInvariants(address user, uint256 previousTotalDeposited, uint256 previousTotalShares, uint256 userAmount, uint256 userShares) public view {
		Invariants.totalDepositIntegrity(yneth.totalDepositedInPool(), previousTotalDeposited, userAmount);
		Invariants.totalAssetsIntegrity(yneth.totalAssets(), previousTotalDeposited, userAmount);
		Invariants.shareMintIntegrity(yneth.totalSupply(), previousTotalShares, userShares);
		Invariants.userSharesIntegrity(yneth.balanceOf(user), 0, userShares);
	}
}

// Add this contract definition outside of your existing contract definitions
contract SelfDestructSender {
    constructor(address payable _target) payable {
        selfdestruct(_target);
    }
}



