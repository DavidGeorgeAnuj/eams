namespace eams;

using { cuid, managed } from '@sap/cds/common';

entity Employee : cuid, managed {
  name             : String(100) @mandatory;
  email            : String(100) @mandatory;
  department       : String(50);
  designation      : String(50);
  reportingManager : Association to Employee;
  userID           : String(100); // links to XSUAA user
  assetRequests    : Association to many AssetRequest on assetRequests.employee = $self;
}

entity Asset : cuid, managed {
  assetTag      : String(20) @mandatory;
  category      : String(20) enum { Laptop; Monitor; Mobile; Other; };
  model         : String(100);
  serialNumber  : String(100);
  status        : String(20) enum { Available; Allocated; UnderMaintenance; Retired; } default 'Available';
  currentHolder : Association to Employee;
}

entity AssetRequest : cuid, managed {
  employee        : Association to Employee;
  asset           : Association to Asset @mandatory;
  requestType     : String(20) enum { Allocation; Return; };
  status          : String(20) enum { Pending; Approved; Rejected; Returned; Cancelled; } default 'Pending';
  justification   : String(500);
  approver        : Association to Employee;
  decisionRemarks : String(500);
  requestDate     : DateTime;
  decisionDate    : DateTime;
}
