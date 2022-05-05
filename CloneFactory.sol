
pragma solidity 0.5.3;
/**
* [深入了解智能合约的最小代理“EIP-1167”](https://blog.csdn.net/chinadefi/article/details/121631038)  \
*/
contract CloneFactory { // implementation of eip-1167 - see https://eips.ethereum.org/EIPS/eip-1167
    function createClone(address target) internal returns (address result) {
        bytes20 targetBytes = bytes20(target);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            result := create(0, clone, 0x37)
        }
    }
}