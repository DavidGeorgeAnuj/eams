const cds = require('@sap/cds');

module.exports = cds.service.impl(async function () {
  const { Assets, AssetsAdmin, AssetRequests } = this.entities;

  // Resolve the current employee record from the logged-in user
  async function getCurrentEmployee(req) {
    const tx = cds.transaction(req);
    const userID = req.user.id;
    const employee = await tx.run(
      SELECT.one.from('eams.Employee').where({ userID })
    );
    if (!employee) req.reject(403, `No employee record linked to user ${userID}`);
    return employee;
  }

  // Validate on create: Allocation needs an Available asset, Return needs the requester to hold it
  this.before('CREATE', AssetRequests, async (req) => {
    const tx = cds.transaction(req);
    const employee = await getCurrentEmployee(req);
    req.data.employee_ID = employee.ID;
    req.data.requestDate = new Date();

    const asset = await tx.run(
      SELECT.one.from('eams.Asset').where({ ID: req.data.asset_ID })
    );
    if (!asset) return req.reject(404, 'Asset not found');

    if (req.data.requestType === 'Allocation' && asset.status !== 'Available') {
      req.reject(400, `Asset ${asset.assetTag} is not available for allocation`);
    }
    if (req.data.requestType === 'Return' && asset.currentHolder_ID !== employee.ID) {
      req.reject(400, `You do not currently hold asset ${asset.assetTag}`);
    }
  });

  // Approve: flips Asset status depending on request type
  this.on('approve', AssetRequests, async (req) => {
    const tx = cds.transaction(req);
    const request = await tx.run(
      SELECT.one.from(AssetRequests, req.params[0])
    );
    if (!request) return req.reject(404, 'Request not found');
    if (request.status !== 'Pending') return req.reject(400, 'Request is not pending');

    const approver = await getCurrentEmployee(req);

    if (request.requestType === 'Allocation') {
      await tx.run(
        UPDATE('eams.Asset').set({ status: 'Allocated', currentHolder_ID: request.employee_ID })
          .where({ ID: request.asset_ID })
      );
      await tx.run(
        UPDATE(AssetRequests).set({ status: 'Approved', approver_ID: approver.ID, decisionDate: new Date(), decisionRemarks: req.data.remarks })
          .where({ ID: request.ID })
      );
    } else {
      await tx.run(
        UPDATE('eams.Asset').set({ status: 'Available', currentHolder_ID: null })
          .where({ ID: request.asset_ID })
      );
      await tx.run(
        UPDATE(AssetRequests).set({ status: 'Returned', approver_ID: approver.ID, decisionDate: new Date(), decisionRemarks: req.data.remarks })
          .where({ ID: request.ID })
      );
    }

    return tx.run(SELECT.one.from(AssetRequests).where({ ID: request.ID }));
  });

  // Reject: requires justification remarks
  this.on('rejectRequest', AssetRequests, async (req) => {
    const tx = cds.transaction(req);
    const request = await tx.run(
      SELECT.one.from(AssetRequests, req.params[0])
    );
    if (!request) return req.reject(404, 'Request not found');
    if (request.status !== 'Pending') return req.reject(400, 'Request is not pending');

    const approver = await getCurrentEmployee(req);

    await tx.run(
      UPDATE(AssetRequests).set({
        status: 'Rejected',
        approver_ID: approver.ID,
        decisionDate: new Date(),
        decisionRemarks: req.data.remarks
      }).where({ ID: request.ID })
    );

    return tx.run(SELECT.one.from(AssetRequests).where({ ID: request.ID }));
  });

  // Cancel: employee withdraws their own pending request
  this.on('cancel', AssetRequests, async (req) => {
    const tx = cds.transaction(req);
    const request = await tx.run(
      SELECT.one.from(AssetRequests, req.params[0])
    );
    if (!request) return req.reject(404, 'Request not found');
    if (request.status !== 'Pending') return req.reject(400, 'Only pending requests can be cancelled');

    await tx.run(
      UPDATE(AssetRequests).set({ status: 'Cancelled' }).where({ ID: request.ID })
    );

    return tx.run(SELECT.one.from(AssetRequests).where({ ID: request.ID }));
  });
});
