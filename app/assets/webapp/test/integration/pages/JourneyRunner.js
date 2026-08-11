sap.ui.define([
    "sap/fe/test/JourneyRunner",
	"assets/test/integration/pages/AssetsList.gen",
	"assets/test/integration/pages/AssetsObjectPage.gen"
], function (JourneyRunner, AssetsListGenerated, AssetsObjectPageGenerated) {
    'use strict';

    const runner = new JourneyRunner({
        launchUrl: sap.ui.require.toUrl('assets') + '/test/flp.html#app-preview',
        pages: {
			onTheAssetsListGenerated: AssetsListGenerated,
			onTheAssetsObjectPageGenerated: AssetsObjectPageGenerated
        },
        async: true
    });

    return runner;
});

