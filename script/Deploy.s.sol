// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/BRSExecutor.sol";

contract DeployBRS is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address bot = 0xa4754998C20981A13A47f77AFC931fA363Ce4DBf;
        address owner = 0xa4754998C20981A13A47f77AFC931fA363Ce4DBf;
        address bgt = 0x656b95E550C07a9ffe548bd4085c72418Ceb1dba;

        vm.startBroadcast(pk);
        new BRSExecutor(bot, owner, bgt);
        vm.stopBroadcast();
    }
}