using { eams } from '../db/schema';

service EAMSService @(path: '/eams') {

  @cds.redirection.target
  @restrict: [
    { grant: 'READ', to: ['Employee', 'Manager', 'AssetAdmin', 'SysAdmin', 'ITSupport'] },
    { grant: ['CREATE', 'DELETE'], to: ['AssetAdmin'] },
    { grant: 'UPDATE', to: ['AssetAdmin', 'ITSupport'] }
  ]
  @Capabilities.InsertRestrictions.Insertable: true
  @odata.draft.enabled
  entity Assets as projection on eams.Asset;

  @requires: 'SysAdmin'
  entity Employees as projection on eams.Employee;

  @restrict: [
    { grant: ['READ', 'CREATE'], to: ['Employee', 'Manager'] },
    { grant: '*', to: ['Manager'] },
    { grant: 'READ', to: ['ITSupport'] }
  ]
  @Capabilities.InsertRestrictions.Insertable: true
  @odata.draft.enabled
  entity AssetRequests as projection on eams.AssetRequest actions {
    action approve(remarks: String) returns AssetRequests;
    action rejectRequest(remarks: String @mandatory) returns AssetRequests;
    action cancel() returns AssetRequests;
  };

  @readonly
  @requires: [ 'AssetAdmin', 'SysAdmin' ]
  entity InventoryReport as select from eams.Asset {
    key category,
    key status,
    count(*) as total : Integer
  } group by category, status;

  @readonly
  entity RequestTypeCodes as projection on eams.RequestTypeCode;
}

annotate EAMSService.AssetRequests with {
  status @readonly;
  decisionRemarks @readonly;
  approver @Core.Computed;
  decisionDate @readonly;
};
