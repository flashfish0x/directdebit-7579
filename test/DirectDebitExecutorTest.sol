// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { RhinestoneModuleKit, ModuleKitHelpers, AccountInstance } from "modulekit/ModuleKit.sol";
import { MODULE_TYPE_EXECUTOR } from "modulekit/accounts/common/interfaces/IERC7579Module.sol";
import { ExecutionLib } from "modulekit/accounts/erc7579/lib/ExecutionLib.sol";
import { DirectDebitExecutor, DirectDebit } from "src/DirectDebitExecutor.sol";

contract DirectDebitExecutorTest is RhinestoneModuleKit, Test {
    using ModuleKitHelpers for *;

    // account and modules
    AccountInstance internal instance;
    DirectDebitExecutor internal executor;

    function setUp() public {
        init();

        // Set the block timestamp to 200 days in the future because starting at 0 will cause
        // problems with DirectDebitError.NotDue
        vm.warp(200 days);

        // Create the executor
        executor = new DirectDebitExecutor();
        vm.label(address(executor), "DirectDebitExecutor");

        // Create the account and install the executor
        instance = makeAccountInstance("ExecutorInstance");
        vm.deal(address(instance.account), 10 ether);
        instance.installModule({
            moduleTypeId: MODULE_TYPE_EXECUTOR,
            module: address(executor),
            data: ""
        });
    }

    function testExec() public {
        // Create a target address and send some ether to it
        address target = makeAddr("target");
        address badTarget = makeAddr("badTarget");
        uint128 value = 1 ether;

        // Get the current balance of the target
        uint256 prevBalance = target.balance;

        // Encode the execution data sent to the account
        DirectDebit memory debit = DirectDebit(
            address(0), // token
            0, // first payment
            uint48(block.timestamp + 10 days), // expires at
            target, // receiver
            1 days, // interval
            value // max amount
        );

        instance.exec({
            target: address(executor),
            value: 0,
            callData: abi.encodeWithSelector(DirectDebitExecutor.createDirectDebit.selector, debit)
        });

        // First payment should be made immediately
        assertEq(executor.canExecute(address(instance.account), 0, value), true);

        vm.prank(badTarget);
        vm.expectRevert(DirectDebitExecutor.DirectDebitNotReceiver.selector);
        executor.execute(address(instance.account), 0, value);

        vm.prank(target);
        vm.expectRevert(DirectDebitExecutor.DirectDebitExceeded.selector);
        executor.execute(address(instance.account), 0, value * 2);

        vm.prank(target);
        executor.execute(address(instance.account), 0, value);

        // Check if the balance of the target has increased
        assertEq(target.balance, prevBalance + value);

        vm.prank(target);
        vm.expectRevert(DirectDebitExecutor.DirectDebitNotDue.selector);
        executor.execute(address(instance.account), 0, value);

        // Check if the last payment timestamp is set correctly
        assertEq(executor.lastPayment(address(instance.account), 0), block.timestamp);

        // Wait for the interval to pass
        skip(debit.interval + 1);
        assertLt(
            executor.lastPayment(address(instance.account), 0) + debit.interval, block.timestamp
        );
        vm.prank(target);
        executor.execute(address(instance.account), 0, value);

        // Check if the balance of the target has increased
        assertEq(target.balance, prevBalance + value * 2);
    }
}
