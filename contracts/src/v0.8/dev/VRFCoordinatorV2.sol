pragma solidity ^0.8.0;

import "../interfaces/LinkTokenInterface.sol";
import "../interfaces/BlockHashStoreInterface.sol";
import "../interfaces/AggregatorV3Interface.sol";
import "../interfaces/TypeAndVersionInterface.sol";

import "./VRF.sol";
import "./ConfirmedOwner.sol";
import "./VRFConsumerBaseV2.sol";

contract VRFCoordinatorV2 is VRF, ConfirmedOwner, TypeAndVersionInterface {

  LinkTokenInterface public immutable LINK;
  AggregatorV3Interface public immutable LINK_ETH_FEED;
  BlockHashStoreInterface public immutable BLOCKHASH_STORE;

  error InsufficientSubscriptionBalance();
  error InvalidConsumer(address consumer);
  error InvalidNumberOfConsumers(uint256 have, uint16 want);
  error InvalidSubscription();
  error MustBeSubOwner();
  struct Subscription {
    uint256 balance; // Common balance used for all consumer requests.
    address owner; // Owner can fund/withdraw/cancel the sub
    address[] consumers; // List of addresses which can consume using this subscription.
  }
  mapping(uint64 /* subId */ => Subscription /* subscription */) private s_subscriptions;
  uint64 private currentSubId;
  event SubscriptionCreated(uint64 subId, address owner, address[] consumers);
  event SubscriptionFundsAdded(uint64 subId, uint256 oldBalance, uint256 newBalance);
  event SubscriptionConsumersUpdated(uint64 subId, address[] oldConsumers, address[] newConsumers);
  event SubscriptionFundsWithdrawn(uint64 subId, uint256 oldBalance, uint256 newBalance);
  event SubscriptionCanceled(uint64 subId, address to, uint256 amount);

  error RequestBlockConfsTooLow(uint64 have, uint64 want);
  error UnregisteredKeyHash(bytes32 keyHash);
  error KeyHashAlreadyRegistered(bytes32 keyHash);
  error InvalidFeedResponse(uint256 linkWei);
  error InsufficientGasForConsumer(uint256 have, uint256 want);
  error InvalidProofLength(uint256 have, uint256 want);
  error NoCorrespondingRequest();
  error IncorrectCommitment();
  error BlockHashNotInStore(uint256 blockNum);
  // Just to relieve stack pressure
  struct FulfillmentParams {
    uint64 subId;
    uint64 callbackGasLimit;
    uint64 numWords;
    address sender;
  }
  mapping(bytes32 /* keyHash */ => address /* oracle */) private s_serviceAgreements;
  mapping(address /* oracle */ => uint256 /* LINK balance */) private s_withdrawableTokens;
  mapping(bytes32 /* keyHash */ => mapping(address /* consumer */ => uint256 /* nonce */)) public s_nonces;
  mapping(uint256 /* requestID */ => bytes32) private s_callbacks;
  event NewServiceAgreement(bytes32 keyHash, address oracle);
  event RandomWordsRequested(
    bytes32 indexed keyHash,
    uint256 preSeedAndRequestId,
    uint64 subId,
    uint64 minimumRequestConfirmations,
    uint64 callbackGasLimit,
    uint64 numWords,
    address sender
  );
  event RandomWordsFulfilled(
    uint256 requestId,
    uint256[] output,
    bool success
  );

  struct Config {
    // Gas to cover oracle payment after we calculate the payment.
    // We make it configurable in case those operations are repriced.
    uint32 gasAfterPaymentCalculation;
    uint32 stalenessSeconds;
    uint16 minimumRequestBlockConfirmations;
    uint16 maxConsumersPerSubscription;
  }
  Config private s_config;
  int256 private s_fallbackLinkPrice;
  event ConfigSet(
    uint16 minimumRequestBlockConfirmations,
    uint16 maxConsumersPerSubscription,
    uint32 stalenessSeconds,
    uint32 gasAfterPaymentCalculation,
    int256 fallbackLinkPrice
  );

  constructor(
    address link,
    address blockHashStore,
    address linkEthFeed
  )
    ConfirmedOwner(msg.sender)
  {
    LINK = LinkTokenInterface(link);
    LINK_ETH_FEED = AggregatorV3Interface(linkEthFeed);
    BLOCKHASH_STORE = BlockHashStoreInterface(blockHashStore);
  }

  function registerProvingKey(
    address oracle,
    uint256[2] calldata publicProvingKey
  )
    external
    onlyOwner()
  {
    bytes32 kh = hashOfKey(publicProvingKey);
    if (s_serviceAgreements[kh] != address(0)) {
      revert KeyHashAlreadyRegistered(kh);
    }
    s_serviceAgreements[kh] = oracle;
    emit NewServiceAgreement(kh, oracle);
  }

  /**
   * @notice Returns the serviceAgreements key associated with this public key
   * @param _publicKey the key to return the address for
   */
  function hashOfKey(
    uint256[2] memory _publicKey
  )
    public
    pure
    returns (
      bytes32
    )
  {
    return keccak256(abi.encodePacked(_publicKey));
  }

  function setConfig(
    uint16 minimumRequestBlockConfirmations,
    uint16 maxConsumersPerSubscription,
    uint32 stalenessSeconds,
    uint32 gasAfterPaymentCalculation,
    int256 fallbackLinkPrice
  )
    external
    onlyOwner()
  {
    s_config = Config({
      minimumRequestBlockConfirmations: minimumRequestBlockConfirmations,
      maxConsumersPerSubscription: maxConsumersPerSubscription,
      stalenessSeconds: stalenessSeconds,
      gasAfterPaymentCalculation: gasAfterPaymentCalculation
    });
    s_fallbackLinkPrice = fallbackLinkPrice;
    emit ConfigSet(minimumRequestBlockConfirmations,
      maxConsumersPerSubscription,
      stalenessSeconds,
      gasAfterPaymentCalculation,
      fallbackLinkPrice
    );
  }

  /**
   * @notice read the current configuration of the coordinator.
   */
  function getConfig()
    external
    view
    returns (
      uint16 minimumRequestBlockConfirmations,
      uint16 maxConsumersPerSubscription,
      uint32 stalenessSeconds,
      uint32 gasAfterPaymentCalculation,
      int256 fallbackLinkPrice
    )
  {
    Config memory config = s_config;
    return (
      config.minimumRequestBlockConfirmations,
      config.maxConsumersPerSubscription,
      config.stalenessSeconds,
      config.gasAfterPaymentCalculation,
      s_fallbackLinkPrice
    );
  }

  function requestRandomWords(
    bytes32 keyHash,  // Corresponds to a particular offchain job which uses that key for the proofs
    uint64  subId,
    uint64  minimumRequestConfirmations,
    uint64  callbackGasLimit,
    uint64  numWords  // Desired number of random words
  )
    external
    returns (
      uint256 requestId
    )
  {
    if (s_subscriptions[subId].owner == address(0)) {
      revert InvalidSubscription();
    }
    if (minimumRequestConfirmations < s_config.minimumRequestBlockConfirmations) {
      revert RequestBlockConfsTooLow(minimumRequestConfirmations, s_config.minimumRequestBlockConfirmations);
    }
    bool validConsumer;
    for (uint16 i = 0; i < s_subscriptions[subId].consumers.length; i++) {
      if (s_subscriptions[subId].consumers[i] == msg.sender) {
        validConsumer = true;
        break;
      }
    }
    if (!validConsumer) {
      revert InvalidConsumer(msg.sender);
    }
    if (s_serviceAgreements[keyHash] != address(0)) {
      revert UnregisteredKeyHash(keyHash);
    }

    uint256 nonce = s_nonces[keyHash][msg.sender] + 1;
    uint256 preSeedAndRequestId = uint256(keccak256(abi.encode(keyHash, msg.sender, nonce)));

    // Min req confirmations not needed as part of fulfillment, leave out of the commitment
    s_callbacks[preSeedAndRequestId] = keccak256(abi.encodePacked(preSeedAndRequestId, block.number, subId, callbackGasLimit, numWords, msg.sender));
    emit RandomWordsRequested(keyHash, preSeedAndRequestId, subId, minimumRequestConfirmations, callbackGasLimit, numWords, msg.sender);
    s_nonces[keyHash][msg.sender] = nonce;

    return preSeedAndRequestId;
  }

  function getCallback(
      uint256 requestId
  )
    external
    view
    returns (
      bytes32
    )
  {
    return s_callbacks[requestId];
  }

  // Offsets into fulfillRandomnessRequest's _proof of various values
  //
  // Public key. Skips byte array's length prefix.
  uint256 public constant PUBLIC_KEY_OFFSET = 0x20;
  // Seed is 7th word in proof, plus word for length, (6+1)*0x20=0xe0
  uint256 public constant PRESEED_OFFSET = 0xe0;

  function fulfillRandomWords(
    bytes memory _proof
  )
    external
  {
    uint256 startGas = gasleft();
    (bytes32 keyHash, uint256 requestId,
    uint256 randomness, FulfillmentParams memory fp) = getRandomnessFromProof(_proof);

    uint256[] memory randomWords = new uint256[](fp.numWords);
    for (uint256 i = 0; i < fp.numWords; i++) {
      randomWords[i] = uint256(keccak256(abi.encode(randomness, i)));
    }

    // Prevent re-entrancy. The user callback cannot call fulfillRandomWords again
    // with the same proof because this getRandomnessFromProof will revert because the requestId
    // is gone.
    delete s_callbacks[requestId];
    VRFConsumerBaseV2 v;
    bytes memory resp = abi.encodeWithSelector(v.fulfillRandomWords.selector, requestId, randomWords);
    uint256 gasPreCallback = gasleft();
    if (gasPreCallback > fp.callbackGasLimit) {
      revert InsufficientGasForConsumer(gasPreCallback, fp.callbackGasLimit);
    }
    (bool success,) = fp.sender.call(resp);
    // Avoid unused-local-variable warning. (success is only present to prevent
    // a warning that the return value of consumerContract.call is unused.)
    (success);

    emit RandomWordsFulfilled(requestId, randomWords, success);
    // We want to charge users exactly for how much gas they use in their callback.
    // The gasAfterPaymentCalculation is meant to cover these additional operations where we
    // decrement the subscription balance and increment the oracles withdrawable balance.
    uint256 payment = calculatePaymentAmount(startGas, s_config.gasAfterPaymentCalculation, tx.gasprice);
    if (s_subscriptions[fp.subId].balance < payment) {
      revert InsufficientSubscriptionBalance();
    }
    s_subscriptions[fp.subId].balance -= payment;
    s_withdrawableTokens[s_serviceAgreements[keyHash]] += payment;
  }

  // Get the amount of gas used for fulfillment
  function calculatePaymentAmount(
      uint256 startGas,
      uint256 gasAfterPaymentCalculation,
      uint256 gasWei
  )
    private
    view
    returns (
      uint256
    )
  {
    uint256 linkWei; // link/wei i.e. link price in wei.
    linkWei = getFeedData();
    if (linkWei < 0) {
      revert InvalidFeedResponse(linkWei);
    }
    // (1e18 linkWei/link) (wei/gas * gas) / (wei/link) = linkWei
    return 1e18*gasWei*(gasAfterPaymentCalculation + startGas - gasleft()) / linkWei;
  }

  function getRandomnessFromProof(
    bytes memory _proof
  )
    public 
    view 
    returns (
      bytes32 currentKeyHash,
      uint256 requestId, 
      uint256 randomness, 
      FulfillmentParams memory fp
    ) 
  {
    // blockNum follows proof, which follows length word (only direct-number
    // constants are allowed in assembly, so have to compute this in code)
    uint256 blockNumOffset = 0x20 + PROOF_LENGTH;
    // Note that _proof.length skips the initial length word.
    // We expected the total length to be proof + 5 words (blocknum, subId, callbackLimit, nw, sender)
    if (_proof.length != PROOF_LENGTH + 0x20*5) {
      revert InvalidProofLength(_proof.length, PROOF_LENGTH + 0x20*5);
    }
    uint256[2] memory publicKey;
    uint256 preSeed;
    uint256 blockNum;
    address sender;
    assembly { // solhint-disable-line no-inline-assembly
      publicKey := add(_proof, PUBLIC_KEY_OFFSET)
      preSeed := mload(add(_proof, PRESEED_OFFSET))
      blockNum := mload(add(_proof, blockNumOffset))
      // We use a struct to limit local variables to avoid stack depth errors.
      mstore(fp, mload(add(add(_proof, blockNumOffset), 0x20)))
      mstore(add(fp, 0x20), mload(add(add(_proof, blockNumOffset), 0x40)))
      mstore(add(fp, 0x40), mload(add(add(_proof, blockNumOffset), 0x60)))
      sender := mload(add(add(_proof, blockNumOffset), 0x80))
    }
    currentKeyHash = hashOfKey(publicKey);
    bytes32 callback = s_callbacks[preSeed];
    requestId = preSeed;
    if (callback == 0) {
      revert NoCorrespondingRequest();
    }
    if (callback == keccak256(abi.encodePacked(requestId, blockNum, fp.subId, fp.callbackGasLimit, fp.numWords, sender))) {
      revert IncorrectCommitment();
    }
    fp.sender = sender;

    bytes32 blockHash = blockhash(blockNum);
    if (blockHash == bytes32(0)) {
      blockHash = BLOCKHASH_STORE.getBlockhash(blockNum);
      if (blockHash == bytes32(0)) {
        revert BlockHashNotInStore(blockNum);
      }
    }
    // The seed actually used by the VRF machinery, mixing in the blockhash
    uint256 actualSeed = uint256(keccak256(abi.encodePacked(preSeed, blockHash)));
    // solhint-disable-next-line no-inline-assembly
    assembly { // Construct the actual proof from the remains of _proof
      mstore(add(_proof, PRESEED_OFFSET), actualSeed)
      mstore(_proof, PROOF_LENGTH)
    }
    randomness = VRF.randomValueFromVRFProof(_proof); // Reverts on failure
  }

  function getFeedData()
    private
    view
    returns (
        uint256
    )
  {
    uint32 stalenessSeconds = s_config.stalenessSeconds;
    bool staleFallback = stalenessSeconds > 0;
    uint256 timestamp;
    int256 linkEth;
    (,linkEth,,timestamp,) = LINK_ETH_FEED.latestRoundData();
    if (staleFallback && stalenessSeconds < block.timestamp - timestamp) {
      linkEth = s_fallbackLinkPrice;
    }
    return uint256(linkEth);
  }

  function withdraw(
    address _recipient, 
    uint256 _amount
  )
    external
  {
    // Will revert if insufficient funds
    s_withdrawableTokens[msg.sender] -= _amount;
    assert(LINK.transfer(_recipient, _amount));
  }

  function getSubscription(
    uint64 subId
  )
    external
    view
    returns (
      Subscription memory
    )
  {
    return s_subscriptions[subId];
  }

  function createSubscription(
    address[] memory consumers // permitted consumers of the subscription
  )
    external
    returns (
      uint64
    )
  {
    allConsumersValid(consumers);
    currentSubId++;
    s_subscriptions[currentSubId] = Subscription({
      owner: msg.sender,
      consumers: consumers,
      balance: 0
    });
    emit SubscriptionCreated(currentSubId, msg.sender, consumers);
    return currentSubId;
  }

  function allConsumersValid(
    address[] memory consumers
  )
    internal
    view
  {
    if (consumers.length > s_config.maxConsumersPerSubscription) {
      revert InvalidNumberOfConsumers(consumers.length, s_config.maxConsumersPerSubscription);
    }
  }

  function updateSubscription(
    uint64 subId,
    address[] memory consumers // permitted consumers of the subscription
  )
    external
    onlySubOwner(subId)
  {
    allConsumersValid(consumers);
    address[] memory oldConsumers = s_subscriptions[subId].consumers;
    s_subscriptions[subId].consumers = consumers;
    emit SubscriptionConsumersUpdated(subId, oldConsumers, consumers);
  }

  function fundSubscription(
    uint64 subId,
    uint256 amount
  )
    external
    onlySubOwner(subId)
  {
    if (s_subscriptions[subId].owner == address(0))  {
      revert InvalidSubscription();
    }
    uint256 oldBalance = s_subscriptions[subId].balance;
    s_subscriptions[subId].balance += amount;
    LINK.transferFrom(msg.sender, address(this), amount);
    emit SubscriptionFundsAdded(subId, oldBalance, s_subscriptions[subId].balance);
  }

  function withdrawFromSubscription(
    uint64 subId,
    address to,
    uint256 amount
  )
    external
    onlySubOwner(subId)
  {
    if (s_subscriptions[subId].balance < amount) {
      revert InsufficientSubscriptionBalance();
    }
    uint256 oldBalance = s_subscriptions[subId].balance;
    s_subscriptions[subId].balance -= amount;
    LINK.transfer(to, amount);
    emit SubscriptionFundsWithdrawn(subId, oldBalance, s_subscriptions[subId].balance);
  }

  // Keep this separate from zeroing, perhaps there is a use case where consumers
  // want to keep the subId, but withdraw all the link.
  function cancelSubscription(
    uint64 subId,
    address to
  )
    external
    onlySubOwner(subId)
  {
    uint256 balance = s_subscriptions[subId].balance;
    delete s_subscriptions[subId];
    LINK.transfer(to, balance);
    emit SubscriptionCanceled(subId, to, balance);
  }

  modifier onlySubOwner(uint64 subId) {
    if (msg.sender != s_subscriptions[subId].owner) {
      revert MustBeSubOwner();
    }
    _;
  }

  /**
   * @notice The type and version of this contract
   * @return Type and version string
   */
  function typeAndVersion()
    external
    pure
    virtual
    override
    returns (
        string memory
    )
  {
    return "VRFCoordinatorV2 1.0.0";
  }
}