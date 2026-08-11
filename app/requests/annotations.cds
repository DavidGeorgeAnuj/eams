using EAMSService as service from '../../srv/service';
annotate service.AssetRequests with @(
    UI.FieldGroup #GeneratedGroup : {
        $Type : 'UI.FieldGroupType',
        Data : [
            {
                $Type : 'UI.DataField',
                Label : 'asset',
                Value : asset_ID,
            },
            {
                $Type : 'UI.DataField',
                Label : 'requestType',
                Value : requestType,
            },
            {
                $Type : 'UI.DataField',
                Label : 'status',
                Value : status,
            },
            {
                $Type : 'UI.DataField',
                Label : 'justification',
                Value : justification,
            },
            {
                $Type : 'UI.DataField',
                Label : 'decisionRemarks',
                Value : decisionRemarks,
            },
            {
                $Type : 'UI.DataField',
                Label : 'requestDate',
                Value : requestDate,
            },
            {
                $Type : 'UI.DataField',
                Label : 'decisionDate',
                Value : decisionDate,
            },
        ],
    },
    UI.Facets : [
        {
            $Type : 'UI.ReferenceFacet',
            ID : 'GeneratedFacet1',
            Label : 'General Information',
            Target : '@UI.FieldGroup#GeneratedGroup',
        },
    ],
    UI.LineItem : [
        {
            $Type : 'UI.DataField',
            Label : 'asset',
            Value : asset_ID,
        },
        {
            $Type : 'UI.DataField',
            Label : 'requestType',
            Value : requestType,
        },
        {
            $Type : 'UI.DataField',
            Label : 'status',
            Value : status,
        },
        {
            $Type : 'UI.DataField',
            Label : 'justification',
            Value : justification,
        },
        {
            $Type : 'UI.DataField',
            Label : 'decisionRemarks',
            Value : decisionRemarks,
        },
        {
            $Type : 'UI.DataField',
            Label : 'requestDate',
            Value : requestDate,
        },
    ],
);

annotate service.AssetRequests with {
    requestType @(
        Common.ValueListWithFixedValues : true,
        Common.ValueList : {
            $Type : 'Common.ValueListType',
            CollectionPath : 'RequestTypeCodes',
            Parameters : [
                {
                    $Type : 'Common.ValueListParameterInOut',
                    LocalDataProperty : requestType,
                    ValueListProperty : 'code',
                },
                {
                    $Type : 'Common.ValueListParameterDisplayOnly',
                    ValueListProperty : 'name',
                },
            ],
        }
    );
};

annotate service.AssetRequests with {
    employee @Common.ValueList : {
        $Type : 'Common.ValueListType',
        CollectionPath : 'Employees',
        Parameters : [
            {
                $Type : 'Common.ValueListParameterInOut',
                LocalDataProperty : employee_ID,
                ValueListProperty : 'ID',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'name',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'email',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'department',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'designation',
            },
        ],
    }
};

annotate service.AssetRequests with {
    asset @Common.ValueList : {
        $Type : 'Common.ValueListType',
        CollectionPath : 'Assets',
        Parameters : [
            {
                $Type : 'Common.ValueListParameterInOut',
                LocalDataProperty : asset_ID,
                ValueListProperty : 'ID',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'assetTag',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'category',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'model',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'serialNumber',
            },
        ],
    }
};

annotate service.AssetRequests with {
    asset @(
        Common.Text : asset.assetTag,
        Common.TextArrangement : #TextOnly
    );
};

annotate service.AssetRequests with {
    approver @Common.ValueList : {
        $Type : 'Common.ValueListType',
        CollectionPath : 'Employees',
        Parameters : [
            {
                $Type : 'Common.ValueListParameterInOut',
                LocalDataProperty : approver_ID,
                ValueListProperty : 'ID',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'name',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'email',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'department',
            },
            {
                $Type : 'Common.ValueListParameterDisplayOnly',
                ValueListProperty : 'designation',
            },
        ],
    }
};


annotate service.AssetRequests with @(
    UI.Identification : [
        {
            $Type : 'UI.DataFieldForAction',
            Action : 'EAMSService.approve',
            Label : 'Approve',
        },
        {
            $Type : 'UI.DataFieldForAction',
            Action : 'EAMSService.rejectRequest',
            Label : 'Reject',
        },
        {
            $Type : 'UI.DataFieldForAction',
            Action : 'EAMSService.cancel',
            Label : 'Cancel',
        },
    ],
);
