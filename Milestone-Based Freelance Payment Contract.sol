// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MilestoneBasedFreelancePayment {
    struct Milestone {
        string description;
        uint256 amount;
        uint256 deadline;
        bool submitted;
        bool approved;
        bool paid;
    }
    
    struct Project {
        address client;
        address freelancer;
        string projectTitle;
        uint256 totalAmount;
        uint256 escrowBalance;
        bool projectCompleted;
        bool cancelled;
    }
    
    Project public project;
    Milestone[] public milestones;
    
    address public arbitrator;
    bool public disputeActive;
    
    enum ContractState { Created, Active, Completed, Disputed, Cancelled }
    ContractState public state;
    
    event MilestoneCreated(uint256 indexed milestoneId, string description, uint256 amount, uint256 deadline);
    event MilestoneSubmitted(uint256 indexed milestoneId, address freelancer);
    event MilestoneApproved(uint256 indexed milestoneId, uint256 amount);
    event PaymentReleased(address indexed recipient, uint256 amount);
    event ProjectCompleted(uint256 totalPaid);
    event DisputeRaised(uint256 indexed milestoneId);
    event DisputeResolved(uint256 indexed milestoneId, bool approved);
    
    modifier onlyClient() {
        require(msg.sender == project.client, "Only client can perform this action");
        _;
    }
    
    modifier onlyFreelancer() {
        require(msg.sender == project.freelancer, "Only freelancer can perform this action");
        _;
    }
    
    modifier onlyArbitrator() {
        require(msg.sender == arbitrator, "Only arbitrator can resolve disputes");
        _;
    }
    
    modifier contractActive() {
        require(state == ContractState.Active, "Contract is not active");
        require(!project.cancelled, "Project has been cancelled");
        _;
    }
    
    constructor() {
        project = Project({
            client: msg.sender,
            freelancer: address(0),
            projectTitle: "Default Project",
            totalAmount: 0,
            escrowBalance: 0,
            projectCompleted: false,
            cancelled: false
        });
        
        arbitrator = msg.sender; // Client acts as arbitrator initially
        state = ContractState.Created;
    }
    
    // Setup function to initialize project after deployment
    function setupProject(
        address _freelancer,
        address _arbitrator,
        string memory _projectTitle
    ) external onlyClient {
        require(state == ContractState.Created, "Project already initialized");
        require(_freelancer != address(0), "Invalid freelancer address");
        require(_arbitrator != address(0), "Invalid arbitrator address");
        
        project.freelancer = _freelancer;
        project.projectTitle = _projectTitle;
        arbitrator = _arbitrator;
    }
    
    // Add milestone function
    function addMilestone(
        string memory _description,
        uint256 _amount,
        uint256 _deadline
    ) external onlyClient payable {
        require(state == ContractState.Created, "Cannot add milestones after project starts");
        require(_amount > 0, "Milestone amount must be greater than 0");
        require(_deadline > block.timestamp, "Deadline must be in the future");
        require(msg.value == _amount, "Must send exact milestone amount");
        
        milestones.push(Milestone({
            description: _description,
            amount: _amount,
            deadline: _deadline,
            submitted: false,
            approved: false,
            paid: false
        }));
        
        project.totalAmount += _amount;
        project.escrowBalance += msg.value;
        
        emit MilestoneCreated(milestones.length - 1, _description, _amount, _deadline);
    }
    
    // Start project function
    function startProject() external onlyClient {
        require(state == ContractState.Created, "Project already started");
        require(project.freelancer != address(0), "Freelancer not set");
        require(milestones.length > 0, "No milestones added");
        
        state = ContractState.Active;
    }
    function submitMilestone(uint256 _milestoneId) external onlyFreelancer contractActive {
        require(_milestoneId < milestones.length, "Invalid milestone ID");
        require(!milestones[_milestoneId].submitted, "Milestone already submitted");
        require(block.timestamp <= milestones[_milestoneId].deadline, "Milestone deadline has passed");
        
        milestones[_milestoneId].submitted = true;
        
        emit MilestoneSubmitted(_milestoneId, msg.sender);
    }
    
    // Core Function 2: Approve milestone and release payment
    function approveMilestone(uint256 _milestoneId) external onlyClient contractActive {
        require(_milestoneId < milestones.length, "Invalid milestone ID");
        require(milestones[_milestoneId].submitted, "Milestone not submitted");
        require(!milestones[_milestoneId].approved, "Milestone already approved");
        require(!milestones[_milestoneId].paid, "Milestone already paid");
        
        milestones[_milestoneId].approved = true;
        milestones[_milestoneId].paid = true;
        
        uint256 paymentAmount = milestones[_milestoneId].amount;
        project.escrowBalance -= paymentAmount;
        
        payable(project.freelancer).transfer(paymentAmount);
        
        emit MilestoneApproved(_milestoneId, paymentAmount);
        emit PaymentReleased(project.freelancer, paymentAmount);
        
        // Check if all milestones are completed
        _checkProjectCompletion();
    }
    
    // Core Function 3: Raise dispute for milestone
    function raiseDispute(uint256 _milestoneId) external contractActive {
        require(msg.sender == project.client || msg.sender == project.freelancer, "Only client or freelancer can raise dispute");
        require(_milestoneId < milestones.length, "Invalid milestone ID");
        require(milestones[_milestoneId].submitted, "Milestone must be submitted first");
        require(!milestones[_milestoneId].approved, "Cannot dispute approved milestone");
        require(!disputeActive, "Another dispute is already active");
        
        disputeActive = true;
        state = ContractState.Disputed;
        
        emit DisputeRaised(_milestoneId);
    }
    
    // Arbitrator resolves disputes
    function resolveDispute(uint256 _milestoneId, bool _approvePayment) external onlyArbitrator {
        require(state == ContractState.Disputed, "No active dispute");
        require(_milestoneId < milestones.length, "Invalid milestone ID");
        require(milestones[_milestoneId].submitted, "Milestone not submitted");
        require(!milestones[_milestoneId].paid, "Milestone already paid");
        
        if (_approvePayment) {
            milestones[_milestoneId].approved = true;
            milestones[_milestoneId].paid = true;
            
            uint256 paymentAmount = milestones[_milestoneId].amount;
            project.escrowBalance -= paymentAmount;
            
            payable(project.freelancer).transfer(paymentAmount);
            emit PaymentReleased(project.freelancer, paymentAmount);
        }
        
        disputeActive = false;
        state = ContractState.Active;
        
        emit DisputeResolved(_milestoneId, _approvePayment);
        
        // Check if all milestones are completed
        _checkProjectCompletion();
    }
    
    // Emergency cancellation (only if no milestones are submitted)
    function cancelProject() external onlyClient {
        require(state == ContractState.Active, "Project cannot be cancelled in current state");
        
        // Check that no milestones have been submitted
        for (uint256 i = 0; i < milestones.length; i++) {
            require(!milestones[i].submitted, "Cannot cancel project with submitted milestones");
        }
        
        project.cancelled = true;
        state = ContractState.Cancelled;
        
        // Refund remaining escrow to client
        if (project.escrowBalance > 0) {
            uint256 refundAmount = project.escrowBalance;
            project.escrowBalance = 0;
            payable(project.client).transfer(refundAmount);
            emit PaymentReleased(project.client, refundAmount);
        }
    }
    
    // Internal function to check project completion
    function _checkProjectCompletion() internal {
        bool allMilestonesCompleted = true;
        
        for (uint256 i = 0; i < milestones.length; i++) {
            if (!milestones[i].paid) {
                allMilestonesCompleted = false;
                break;
            }
        }
        
        if (allMilestonesCompleted) {
            project.projectCompleted = true;
            state = ContractState.Completed;
            emit ProjectCompleted(project.totalAmount);
        }
    }
    
    // View functions
    function getMilestone(uint256 _milestoneId) external view returns (
        string memory description,
        uint256 amount,
        uint256 deadline,
        bool submitted,
        bool approved,
        bool paid
    ) {
        require(_milestoneId < milestones.length, "Invalid milestone ID");
        Milestone memory milestone = milestones[_milestoneId];
        return (
            milestone.description,
            milestone.amount,
            milestone.deadline,
            milestone.submitted,
            milestone.approved,
            milestone.paid
        );
    }
    
    function getMilestoneCount() external view returns (uint256) {
        return milestones.length;
    }
    
    function getProjectDetails() external view returns (
        address client,
        address freelancer,
        string memory projectTitle,
        uint256 totalAmount,
        uint256 escrowBalance,
        bool projectCompleted,
        ContractState currentState
    ) {
        return (
            project.client,
            project.freelancer,
            project.projectTitle,
            project.totalAmount,
            project.escrowBalance,
            project.projectCompleted,
            state
        );
    }
    
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
