
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

/**
 * @title Decentralized Escrow Service
 * @dev Implements an escrow system where a buyer can deposit funds that will be released to the seller
 * once both parties agree or in case of disputes, by an arbitrator.
 */
contract DecentralizedEscrow {
    // Enum to track the state of each escrow transaction
    enum State { AWAITING_PAYMENT, AWAITING_DELIVERY, COMPLETE, REFUNDED, DISPUTED }
    
    // Struct to store escrow transaction details
    struct Transaction {
        address payable buyer;
        address payable seller;
        address arbitrator;
        uint256 amount;
        uint256 fee;
        uint256 createdAt;
        uint256 completedAt;
        State state;
        string description;
        bytes32 transactionHash;
        bool buyerConfirmed;
        bool sellerConfirmed;
    }
    
    // Mapping from transaction hash to Transaction struct
    mapping(bytes32 => Transaction) public transactions;
    
    // Array to track all transaction hashes
    bytes32[] public transactionHashes;
    
    // Platform fee percentage (in basis points, 1% = 100 basis points)
    uint256 public feePercentage = 100; // Default 1%
    
    // Platform owner who can update the fee
    address public owner;
    
    // Events for different actions in the contract
    event TransactionCreated(bytes32 indexed transactionHash, address indexed buyer, address indexed seller, uint256 amount, string description);
    event PaymentDeposited(bytes32 indexed transactionHash, address indexed buyer, uint256 amount);
    event DeliveryConfirmed(bytes32 indexed transactionHash, address confirmer);
    event FundsReleased(bytes32 indexed transactionHash, address indexed seller, uint256 amount);
    event TransactionRefunded(bytes32 indexed transactionHash, address indexed buyer, uint256 amount);
    event DisputeRaised(bytes32 indexed transactionHash, address initiator);
    event DisputeResolved(bytes32 indexed transactionHash, address arbitrator, address recipient, uint256 amount);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    
    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }
    
    modifier onlyBuyer(bytes32 _transactionHash) {
        require(msg.sender == transactions[_transactionHash].buyer, "Only buyer can call this function");
        _;
    }
    
    modifier onlySeller(bytes32 _transactionHash) {
        require(msg.sender == transactions[_transactionHash].seller, "Only seller can call this function");
        _;
    }
    
    modifier onlyArbitrator(bytes32 _transactionHash) {
        require(msg.sender == transactions[_transactionHash].arbitrator, "Only arbitrator can call this function");
        _;
    }
    
    modifier onlyInvolvedParty(bytes32 _transactionHash) {
        require(
            msg.sender == transactions[_transactionHash].buyer || 
            msg.sender == transactions[_transactionHash].seller,
            "Only involved parties can call this function"
        );
        _;
    }
    
    modifier transactionExists(bytes32 _transactionHash) {
        require(transactions[_transactionHash].buyer != address(0), "Transaction does not exist");
        _;
    }
    
    modifier inState(bytes32 _transactionHash, State _state) {
        require(transactions[_transactionHash].state == _state, "Transaction is not in the required state");
        _;
    }
    
    // Constructor sets the contract deployer as the owner
    constructor() {
        owner = msg.sender;
    }
    
    /**
     * @dev Create a new escrow transaction
     * @param _seller The address of the seller
     * @param _arbitrator The address of the arbitrator
     * @param _description Description of the transaction
     * @return transactionHash The hash of the created transaction
     */
    function createTransaction(
        address payable _seller,
        address _arbitrator,
        string memory _description
    ) external returns (bytes32 transactionHash) {
        require(_seller != address(0), "Invalid seller address");
        require(_arbitrator != address(0), "Invalid arbitrator address");
        
        // Generate a unique transaction hash
        transactionHash = keccak256(
            abi.encodePacked(
                msg.sender,
                _seller,
                _arbitrator,
                block.timestamp,
                _description
            )
        );
        
        // Ensure transaction hash is unique
        require(transactions[transactionHash].buyer == address(0), "Transaction already exists");
        
        // Create a new transaction
        Transaction memory newTransaction = Transaction({
            buyer: payable(msg.sender),
            seller: _seller,
            arbitrator: _arbitrator,
            amount: 0,
            fee: 0,
            createdAt: block.timestamp,
            completedAt: 0,
            state: State.AWAITING_PAYMENT,
            description: _description,
            transactionHash: transactionHash,
            buyerConfirmed: false,
            sellerConfirmed: false
        });
        
        // Store the new transaction
        transactions[transactionHash] = newTransaction;
        transactionHashes.push(transactionHash);
        
        emit TransactionCreated(transactionHash, msg.sender, _seller, 0, _description);
        
        return transactionHash;
    }
    
    /**
     * @dev Deposit funds into an escrow transaction
     * @param _transactionHash The hash of the transaction
     */
    function depositFunds(bytes32 _transactionHash) 
        external 
        payable 
        transactionExists(_transactionHash)
        onlyBuyer(_transactionHash)
        inState(_transactionHash, State.AWAITING_PAYMENT)
    {
        require(msg.value > 0, "Must deposit more than 0");
        
        Transaction storage transaction = transactions[_transactionHash];
        
        // Calculate fee
        uint256 fee = (msg.value * feePercentage) / 10000;
        
        // Update transaction details
        transaction.amount = msg.value - fee;
        transaction.fee = fee;
        transaction.state = State.AWAITING_DELIVERY;
        
        emit PaymentDeposited(_transactionHash, msg.sender, msg.value);
    }
    
    /**
     * @dev Confirm delivery as buyer or seller
     * @param _transactionHash The hash of the transaction
     */
    function confirmDelivery(bytes32 _transactionHash) 
        external 
        transactionExists(_transactionHash)
        onlyInvolvedParty(_transactionHash)
        inState(_transactionHash, State.AWAITING_DELIVERY)
    {
        Transaction storage transaction = transactions[_transactionHash];
        
        if (msg.sender == transaction.buyer) {
            transaction.buyerConfirmed = true;
        } else {
            transaction.sellerConfirmed = true;
        }
        
        emit DeliveryConfirmed(_transactionHash, msg.sender);
        
        // If both parties confirm, release the funds
        if (transaction.buyerConfirmed && transaction.sellerConfirmed) {
            _releaseFunds(_transactionHash);
        }
    }
    
    /**
     * @dev Raise a dispute for an escrow transaction
     * @param _transactionHash The hash of the transaction
     */
    function raiseDispute(bytes32 _transactionHash)
        external
        transactionExists(_transactionHash)
        onlyInvolvedParty(_transactionHash)
        inState(_transactionHash, State.AWAITING_DELIVERY)
    {
        Transaction storage transaction = transactions[_transactionHash];
        transaction.state = State.DISPUTED;
        
        emit DisputeRaised(_transactionHash, msg.sender);
    }
    
    /**
     * @dev Resolve a dispute by the arbitrator
     * @param _transactionHash The hash of the transaction
     * @param _toSeller If true, funds go to seller; if false, funds are refunded to buyer
     */
    function resolveDispute(bytes32 _transactionHash, bool _toSeller)
        external
        transactionExists(_transactionHash)
        onlyArbitrator(_transactionHash)
        inState(_transactionHash, State.DISPUTED)
    {
        Transaction storage transaction = transactions[_transactionHash];
        
        if (_toSeller) {
            _releaseFunds(_transactionHash);
        } else {
            _refundBuyer(_transactionHash);
        }
        
        address recipient = _toSeller ? transaction.seller : transaction.buyer;
        emit DisputeResolved(_transactionHash, msg.sender, recipient, transaction.amount);
    }
    
    /**
     * @dev Release funds from escrow to the seller (internal function)
     * @param _transactionHash The hash of the transaction
     */
    function _releaseFunds(bytes32 _transactionHash) private {
        Transaction storage transaction = transactions[_transactionHash];
        transaction.state = State.COMPLETE;
        transaction.completedAt = block.timestamp;
        
        // Transfer fee to contract owner
        payable(owner).transfer(transaction.fee);
        
        // Transfer funds to seller
        transaction.seller.transfer(transaction.amount);
        
        emit FundsReleased(_transactionHash, transaction.seller, transaction.amount);
    }
    
    /**
     * @dev Refund funds from escrow to the buyer (internal function)
     * @param _transactionHash The hash of the transaction
     */
    function _refundBuyer(bytes32 _transactionHash) private {
        Transaction storage transaction = transactions[_transactionHash];
        transaction.state = State.REFUNDED;
        transaction.completedAt = block.timestamp;
        
        // Refund full amount including fee back to buyer
        transaction.buyer.transfer(transaction.amount + transaction.fee);
        
        emit TransactionRefunded(_transactionHash, transaction.buyer, transaction.amount + transaction.fee);
    }
    
    /**
     * @dev Update the platform fee percentage
     * @param _newFeePercentage New fee percentage in basis points
     */
    function updateFee(uint256 _newFeePercentage) external onlyOwner {
        require(_newFeePercentage <= 1000, "Fee cannot exceed 10%");
        
        uint256 oldFee = feePercentage;
        feePercentage = _newFeePercentage;
        
        emit FeeUpdated(oldFee, feePercentage);
    }
    
    /**
     * @dev Get the total number of transactions
     * @return The number of transactions
     */
    function getTransactionCount() external view returns (uint256) {
        return transactionHashes.length;
    }
    
    /**
     * @dev Get transactions by a specific address (buyer or seller)
     * @param _address The address to look up
     * @return Array of transaction hashes
     */
    function getTransactionsByAddress(address _address) external view returns (bytes32[] memory) {
        uint256 count = 0;
        
        // First pass to count relevant transactions
        for (uint256 i = 0; i < transactionHashes.length; i++) {
            Transaction memory transaction = transactions[transactionHashes[i]];
            if (transaction.buyer == _address || transaction.seller == _address) {
                count++;
            }
        }
        
        // Second pass to populate the array
        bytes32[] memory result = new bytes32[](count);
        uint256 resultIndex = 0;
        
        for (uint256 i = 0; i < transactionHashes.length; i++) {
            Transaction memory transaction = transactions[transactionHashes[i]];
            if (transaction.buyer == _address || transaction.seller == _address) {
                result[resultIndex] = transactionHashes[i];
                resultIndex++;
            }
        }
        
        return result;
    }
    
    /**
     * @dev Get contract balance
     * @return The current balance of the contract
     */
    function getContractBalance() external view onlyOwner returns (uint256) {
        return address(this).balance;
    }
}
