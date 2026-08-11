sap.ui.define([
    "sap/fe/test/JourneyRunner",
	"requests/test/integration/pages/AssetRequestsList.gen",
	"requests/test/integration/pages/AssetRequestsObjectPage.gen"
], function (JourneyRunner, AssetRequestsListGenerated, AssetRequestsObjectPageGenerated) {
    'use strict';

    const runner = new JourneyRunner({
        launchUrl: sap.ui.require.toUrl('requests') + '/test/flp.html#app-preview',
        pages: {
			onTheAssetRequestsListGenerated: AssetRequestsListGenerated,
			onTheAssetRequestsObjectPageGenerated: AssetRequestsObjectPageGenerated
        },
        async: true
    });

    return runner;
});

