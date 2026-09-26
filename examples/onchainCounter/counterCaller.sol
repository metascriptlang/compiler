pragma solidity 0.8.30;

interface MetaScriptCounter {
    function get() external view returns (uint64);
    function increment(uint64 amount) external returns (uint64);
    function sender() external view returns (address);
    function storeThenFail(uint64 amount) external returns (uint64);
}

interface ArbWasm {
    function codehashVersion(bytes32 codehash) external view returns (uint16 version);
    error ProgramNotActivated();
    error ProgramNeedsUpgrade(uint16 version, uint16 stylusVersion);
    error ProgramExpired(uint64 ageInSeconds);
    function activateProgram(address program) external payable returns (uint16 version, uint256 fee);
}

contract CounterCaller {
    error ArbitrumError(uint32 code);

    MetaScriptCounter public immutable counter;

    event Transition(uint64 beforeValue, uint64 amount, uint64 afterValue);
    event Rejection(bytes input, bytes reason);

    constructor(address program) {
        require(program.code.length != 0, "counter has no code");
        counter = MetaScriptCounter(program);
    }

    function incrementAndCheck(uint64 amount, uint64 beforeValue, uint64 afterValue) external {
        require(counter.get() == beforeValue, "unexpected initial state");
        require(counter.sender() == address(this), "wrong Solidity caller");
        require(counter.increment(amount) == afterValue, "wrong increment result");
        require(counter.get() == afterValue, "write did not persist");
        emit Transition(beforeValue, amount, afterValue);
    }

    function proveRejections() external {
        require(counter.get() == 12, "rejection proof requires 12");
        reject(abi.encodeCall(MetaScriptCounter.storeThenFail, (999)), 6);
        require(counter.get() == 12, "reverted write persisted");
        reject(abi.encodeCall(MetaScriptCounter.increment, (0)), 6);
        reject(abi.encodeCall(MetaScriptCounter.increment, (1000000)), 6);
        reject(abi.encodePacked(MetaScriptCounter.increment.selector, bytes32(uint256(1) << 64)), 2);
        reject(abi.encodePacked(MetaScriptCounter.increment.selector), 0);
        reject(abi.encodePacked(abi.encodeCall(MetaScriptCounter.increment, (1)), bytes1(0)), 0);
        reject(hex"ffffffff", 4);
        require(counter.get() == 12, "rejected call changed state");
    }

    function proveLimit() external {
        require(counter.get() == 1000000, "limit proof requires 1000000");
        reject(abi.encodeCall(MetaScriptCounter.increment, (1)), 6);
        require(counter.get() == 1000000, "limit rejection changed state");
    }

    function reject(bytes memory input, uint32 errorCode) private {
        (bool success, bytes memory reason) = address(counter).call(input);
        require(!success, "invalid call succeeded");
        require(
            keccak256(reason) == keccak256(abi.encodeWithSelector(ArbitrumError.selector, errorCode)),
            "unexpected revert payload"
        );
        emit Rejection(input, reason);
    }
}

contract CounterSimulation {
    constructor(bytes memory initCode) payable {
        address program;
        assembly {
            program := create(0, add(initCode, 32), mload(initCode))
        }
        require(program != address(0), "WASM deployment failed");
        ArbWasm arbWasm = ArbWasm(address(0x71));
        uint16 version;
        uint256 fee;
        try arbWasm.codehashVersion(program.codehash) returns (uint16 activeVersion) {
            version = activeVersion;
        } catch (bytes memory reason) {
            bytes4 kind = bytes4(reason);
            require(
                kind == ArbWasm.ProgramNotActivated.selector
                    || kind == ArbWasm.ProgramNeedsUpgrade.selector
                    || kind == ArbWasm.ProgramExpired.selector,
                "unexpected activation status"
            );
            (version, fee) = arbWasm.activateProgram{value: 1 ether}(program);
        }
        CounterCaller caller = new CounterCaller(program);
        caller.incrementAndCheck(7, 0, 7);
        caller.incrementAndCheck(5, 7, 12);
        caller.proveRejections();
        caller.incrementAndCheck(999988, 12, 1000000);
        caller.proveLimit();
        uint64 finalValue = MetaScriptCounter(program).get();
        bytes memory proof = abi.encode(program, address(caller), version, fee, finalValue);
        assembly {
            return(add(proof, 32), mload(proof))
        }
    }
}
