// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title PropertyRentalManagement
 * @dev ระบบจัดการสัญญาเช่าอสังหาริมทรัพย์และเงินประกัน (Smart Property Rental & Deposit Management)
 *      สำหรับ บริษัท SmartLiving Property
 *      Contract Address: 0xa0Bc91cE812D2C03cf39633Dbd1A2D6bBa4d9Ee6
 */
contract PropertyRentalManagement {

    // --- ENUMS ---
    enum PropertyStatus { Available, Rented, Inactive }
    enum AgreementStatus { Created, Confirmed, Active, Inspected, Disputed, Completed, Cancelled }

    // --- STRUCTS ---
    struct Property {
        uint256 propertyId;
        address payable landlord;
        string roomInfo;             // ข้อมูลห้องพัก / เลขที่ห้อง
        uint256 rentPrice;           // ค่าเช่าต่องวด (หน่วย Wei)
        uint256 depositRequired;     // เงินประกันที่ต้องวาง (หน่วย Wei)
        PropertyStatus status;
        bool exists;
    }

    struct RentalAgreement {
        uint256 agreementId;
        uint256 propertyId;
        address payable landlord;
        address payable tenant;
        uint256 rentPrice;           // ค่าเช่าต่องวด
        uint256 depositRequired;     // ยอดเงินประกันที่ตกลง
        uint256 depositBalance;      // ยอดเงินประกันที่เก็บอยู่ใน Contract ปัจจุบัน
        uint256 startTime;           // วันเริ่มต้นสัญญา (Unix Timestamp)
        uint256 endTime;             // วันสิ้นสุดสัญญา (Unix Timestamp)
        string terms;                // เงื่อนไขและข้อตกลงสำคัญ
        bool landlordConfirmed;      // เจ้าของห้องยืนยันแล้วหรือไม่
        bool tenantConfirmed;        // ผู้เช่ายืนยันแล้วหรือไม่
        AgreementStatus status;
        bool exists;
    }

    struct RentalPaymentRecord {
        uint256 paymentId;
        uint256 agreementId;
        uint256 periodIndex;         // งวดที่ชำระ
        uint256 amount;              // จำนวนเงินค่าเช่า (Wei)
        uint256 paidTimestamp;       // เวลาที่ชำระ
        address paidBy;
    }

    struct InspectionResult {
        bool isInspected;
        uint256 deductionAmount;     // จำนวนเงินประกันที่ขอหักเป็นค่าเสียหาย
        string deductionReason;      // เหตุผลการหักเงินประกัน
        bool tenantAgreed;           // ผู้เช่ายินยอมรับการหักเงินหรือไม่
    }

    struct DisputeRecord {
        bool isDisputed;
        address raisedBy;
        string disputeReason;        // เหตุผลข้อโต้แย้ง
        uint256 raisedTimestamp;
        bool isResolved;
        uint256 payoutToLandlord;    // ยอดเงินที่ตัดสินจ่ายให้เจ้าของห้อง
        uint256 refundToTenant;      // ยอดเงินที่ตัดสินคืนให้ผู้เช่า
        string resolutionNotes;      // บันทึกผลการพิจารณาของผู้มีอำนาจ
    }

    // --- STATE VARIABLES ---
    address public arbitrator;       // ผู้มีอำนาจชี้ขาดข้อพิพาท (SmartLiving Property Admin)
    uint256 public propertyCount;
    uint256 public agreementCount;
    uint256 public paymentCount;

    mapping(uint256 => Property) public properties;
    mapping(uint256 => RentalAgreement) internal _agreements;
    mapping(uint256 => InspectionResult) public inspectionResults;
    mapping(uint256 => DisputeRecord) public disputeRecords;
    mapping(uint256 => RentalPaymentRecord[]) public agreementPaymentHistory;

    // ระบบ Reentrancy Guard
    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "Reentrant call");
        _locked = 2;
        _;
        _locked = 1;
    }

    // --- MODIFIERS ---
    modifier onlyArbitrator() {
        require(msg.sender == arbitrator, "Only arbitrator");
        _;
    }

    modifier onlyLandlord(uint256 _propertyId) {
        require(properties[_propertyId].landlord == msg.sender, "Only landlord");
        _;
    }

    modifier onlyAgreementParty(uint256 _agreementId) {
        RentalAgreement storage ag = _agreements[_agreementId];
        require(msg.sender == ag.landlord || msg.sender == ag.tenant, "Only party");
        _;
    }

    // --- EVENTS ---
    event PropertyRegistered(uint256 indexed propertyId, address indexed landlord, string roomInfo, uint256 rentPrice, uint256 depositRequired);
    event AgreementCreated(uint256 indexed agreementId, uint256 indexed propertyId, address indexed landlord, address tenant, uint256 startTime, uint256 endTime);
    event AgreementConfirmed(uint256 indexed agreementId, address indexed confirmedBy);
    event SecurityDepositReceived(uint256 indexed agreementId, address indexed tenant, uint256 amount);
    event RentPaymentRecorded(uint256 indexed paymentId, uint256 indexed agreementId, uint256 periodIndex, uint256 amount, address indexed paidBy);
    event RoomInspected(uint256 indexed agreementId, uint256 deductionAmount, string deductionReason);
    event SecurityDepositRefunded(uint256 indexed agreementId, uint256 payoutToLandlord, uint256 refundToTenant);
    event DisputeRaised(uint256 indexed agreementId, address indexed raisedBy, string reason);
    event DisputeResolved(uint256 indexed agreementId, uint256 payoutToLandlord, uint256 refundToTenant, string resolutionNotes);

    constructor() {
        arbitrator = msg.sender;
    }

    // 1. ลงทะเบียนทรัพย์สิน (Register Property)
    function registerProperty(
        string memory _roomInfo,
        uint256 _rentPrice,
        uint256 _depositRequired
    ) external returns (uint256) {
        require(bytes(_roomInfo).length > 0, "Empty info");
        require(_rentPrice > 0, "Zero rent");
        require(_depositRequired > 0, "Zero deposit");

        propertyCount++;
        uint256 newPropertyId = propertyCount;

        properties[newPropertyId] = Property({
            propertyId: newPropertyId,
            landlord: payable(msg.sender),
            roomInfo: _roomInfo,
            rentPrice: _rentPrice,
            depositRequired: _depositRequired,
            status: PropertyStatus.Available,
            exists: true
        });

        emit PropertyRegistered(newPropertyId, msg.sender, _roomInfo, _rentPrice, _depositRequired);
        return newPropertyId;
    }

    // 2. สร้างสัญญาเช่า (Create Rental Agreement)
    function createRentalAgreement(
        uint256 _propertyId,
        address payable _tenant,
        uint256 _startTime,
        uint256 _endTime,
        string memory _terms
    ) external onlyLandlord(_propertyId) returns (uint256) {
        Property storage prop = properties[_propertyId];
        require(prop.exists, "No property");
        require(prop.status == PropertyStatus.Available, "Not available");
        require(_tenant != address(0) && _tenant != msg.sender, "Invalid tenant");
        require(_startTime < _endTime, "Invalid time");
        require(bytes(_terms).length > 0, "Empty terms");

        agreementCount++;
        uint256 newAgreementId = agreementCount;

        _agreements[newAgreementId] = RentalAgreement({
            agreementId: newAgreementId,
            propertyId: _propertyId,
            landlord: payable(msg.sender),
            tenant: _tenant,
            rentPrice: prop.rentPrice,
            depositRequired: prop.depositRequired,
            depositBalance: 0,
            startTime: _startTime,
            endTime: _endTime,
            terms: _terms,
            landlordConfirmed: true,
            tenantConfirmed: false,
            status: AgreementStatus.Created,
            exists: true
        });

        emit AgreementCreated(newAgreementId, _propertyId, msg.sender, _tenant, _startTime, _endTime);
        return newAgreementId;
    }

    // 3. ยืนยันสัญญา (Confirm Agreement)
    function confirmAgreement(uint256 _agreementId) external onlyAgreementParty(_agreementId) {
        RentalAgreement storage ag = _agreements[_agreementId];
        require(ag.exists, "No agreement");
        require(ag.status == AgreementStatus.Created, "Invalid status");

        if (msg.sender == ag.landlord) {
            require(!ag.landlordConfirmed, "Already confirmed");
            ag.landlordConfirmed = true;
        } else if (msg.sender == ag.tenant) {
            require(!ag.tenantConfirmed, "Already confirmed");
            ag.tenantConfirmed = true;
        }

        emit AgreementConfirmed(_agreementId, msg.sender);

        if (ag.landlordConfirmed && ag.tenantConfirmed) {
            ag.status = AgreementStatus.Confirmed;
        }
    }

    // 4. ฝากเงินประกัน (Deposit Security)
    function depositSecurity(uint256 _agreementId) external payable nonReentrant {
        RentalAgreement storage ag = _agreements[_agreementId];
        require(ag.exists, "No agreement");
        require(msg.sender == ag.tenant, "Only tenant");
        require(ag.status == AgreementStatus.Confirmed, "Both must confirm");
        require(msg.value == ag.depositRequired, "Incorrect deposit");
        require(ag.depositBalance == 0, "Deposit paid");

        ag.depositBalance = msg.value;
        ag.status = AgreementStatus.Active;
        properties[ag.propertyId].status = PropertyStatus.Rented;

        emit SecurityDepositReceived(_agreementId, msg.sender, msg.value);
    }

    // 5. บันทึกค่าเช่า (Record Rental Payment)
    function recordRentalPayment(uint256 _agreementId) external payable nonReentrant {
        RentalAgreement storage ag = _agreements[_agreementId];
        require(ag.exists, "No agreement");
        require(msg.sender == ag.tenant, "Only tenant");
        require(ag.status == AgreementStatus.Active, "Not active");
        require(msg.value == ag.rentPrice, "Incorrect rent");

        paymentCount++;
        uint256 periodIdx = agreementPaymentHistory[_agreementId].length + 1;

        agreementPaymentHistory[_agreementId].push(RentalPaymentRecord({
            paymentId: paymentCount,
            agreementId: _agreementId,
            periodIndex: periodIdx,
            amount: msg.value,
            paidTimestamp: block.timestamp,
            paidBy: msg.sender
        }));

        (bool success, ) = ag.landlord.call{value: msg.value}("");
        require(success, "Transfer failed");

        emit RentPaymentRecorded(paymentCount, _agreementId, periodIdx, msg.value, msg.sender);
    }

    // 6. ตรวจสภาพห้องและคืนเงินประกัน (Inspection & Refund Deposit)
    function recordRoomInspection(
        uint256 _agreementId,
        uint256 _deductionAmount,
        string memory _deductionReason
    ) external onlyAgreementParty(_agreementId) {
        RentalAgreement storage ag = _agreements[_agreementId];
        require(msg.sender == ag.landlord, "Only landlord");
        require(ag.status == AgreementStatus.Active, "Must be active");
        require(_deductionAmount <= ag.depositBalance, "Exceeds deposit");

        if (_deductionAmount > 0) {
            require(bytes(_deductionReason).length > 0, "Reason required");
        }

        inspectionResults[_agreementId] = InspectionResult({
            isInspected: true,
            deductionAmount: _deductionAmount,
            deductionReason: _deductionReason,
            tenantAgreed: (_deductionAmount == 0)
        });

        ag.status = AgreementStatus.Inspected;

        emit RoomInspected(_agreementId, _deductionAmount, _deductionReason);
    }

    function agreeToInspectionDeduction(uint256 _agreementId) external {
        RentalAgreement storage ag = _agreements[_agreementId];
        require(msg.sender == ag.tenant, "Only tenant");
        require(ag.status == AgreementStatus.Inspected, "Not inspected");
        InspectionResult storage insp = inspectionResults[_agreementId];
        require(insp.isInspected, "Not inspected");

        insp.tenantAgreed = true;
    }

    function refundDeposit(uint256 _agreementId) external nonReentrant {
        RentalAgreement storage ag = _agreements[_agreementId];
        require(ag.status == AgreementStatus.Inspected, "Must be inspected");
        InspectionResult storage insp = inspectionResults[_agreementId];
        require(insp.isInspected, "Not inspected");
        require(insp.tenantAgreed, "Tenant not agreed");

        uint256 deduction = insp.deductionAmount;
        uint256 totalDeposit = ag.depositBalance;
        require(deduction <= totalDeposit, "Exceeds balance");

        uint256 refundToTenant = totalDeposit - deduction;

        ag.depositBalance = 0;
        ag.status = AgreementStatus.Completed;
        properties[ag.propertyId].status = PropertyStatus.Available;

        if (deduction > 0) {
            (bool payLandlord, ) = ag.landlord.call{value: deduction}("");
            require(payLandlord, "Pay landlord failed");
        }

        if (refundToTenant > 0) {
            (bool payTenant, ) = ag.tenant.call{value: refundToTenant}("");
            require(payTenant, "Refund failed");
        }

        emit SecurityDepositRefunded(_agreementId, deduction, refundToTenant);
    }

    // 7. จัดการข้อโต้แย้ง (Rental Dispute)
    function raiseDispute(uint256 _agreementId, string memory _disputeReason) external onlyAgreementParty(_agreementId) {
        RentalAgreement storage ag = _agreements[_agreementId];
        require(ag.status == AgreementStatus.Active || ag.status == AgreementStatus.Inspected, "Invalid status");
        require(ag.depositBalance > 0, "No deposit");
        require(!disputeRecords[_agreementId].isDisputed, "Already disputed");
        require(bytes(_disputeReason).length > 0, "Reason required");

        ag.status = AgreementStatus.Disputed;

        disputeRecords[_agreementId] = DisputeRecord({
            isDisputed: true,
            raisedBy: msg.sender,
            disputeReason: _disputeReason,
            raisedTimestamp: block.timestamp,
            isResolved: false,
            payoutToLandlord: 0,
            refundToTenant: 0,
            resolutionNotes: ""
        });

        emit DisputeRaised(_agreementId, msg.sender, _disputeReason);
    }

    function resolveDispute(
        uint256 _agreementId,
        uint256 _payoutToLandlord,
        uint256 _refundToTenant,
        string memory _resolutionNotes
    ) external onlyArbitrator nonReentrant {
        RentalAgreement storage ag = _agreements[_agreementId];
        require(ag.status == AgreementStatus.Disputed, "Not disputed");
        DisputeRecord storage dispute = disputeRecords[_agreementId];
        require(dispute.isDisputed && !dispute.isResolved, "Not valid dispute");

        uint256 totalDeposit = ag.depositBalance;
        require(_payoutToLandlord + _refundToTenant == totalDeposit, "Payout mismatch");

        dispute.isResolved = true;
        dispute.payoutToLandlord = _payoutToLandlord;
        dispute.refundToTenant = _refundToTenant;
        dispute.resolutionNotes = _resolutionNotes;

        ag.depositBalance = 0;
        ag.status = AgreementStatus.Completed;
        properties[ag.propertyId].status = PropertyStatus.Available;

        if (_payoutToLandlord > 0) {
            (bool successLandlord, ) = ag.landlord.call{value: _payoutToLandlord}("");
            require(successLandlord, "Landlord transfer failed");
        }

        if (_refundToTenant > 0) {
            (bool successTenant, ) = ag.tenant.call{value: _refundToTenant}("");
            require(successTenant, "Tenant refund failed");
        }

        emit DisputeResolved(_agreementId, _payoutToLandlord, _refundToTenant, _resolutionNotes);
    }

    // VIEW FUNCTIONS
    function getRentalPaymentHistory(uint256 _agreementId) external view returns (RentalPaymentRecord[] memory) {
        return agreementPaymentHistory[_agreementId];
    }

    function getProperty(uint256 _propertyId) external view returns (Property memory) {
        return properties[_propertyId];
    }

    function getAgreement(uint256 _agreementId) external view returns (RentalAgreement memory) {
        return _agreements[_agreementId];
    }

    function getDispute(uint256 _agreementId) external view returns (DisputeRecord memory) {
        return disputeRecords[_agreementId];
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
