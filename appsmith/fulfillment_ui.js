export default {
  async refreshSelectedOrder() {
    const id = appsmith.store.fulfillment_selected_order_id;
    const res = await apiFulfillmentListOrders.run();
    if (id !== appsmith.store.fulfillment_selected_order_id) return null;
    if (!res || res.ok === false) throw new Error(res?.error || "Could not refresh orders");
    const row = (res.orders || []).find(r => String(r.airtable_record_id) === String(id));
    if (row) await storeValue("fulfillment_selected_order", row);
    return this.reloadOrderDetail();
  },

  async dispatchSelectedOrder() {
    const id = appsmith.store.fulfillment_selected_order_id;
    if (!id || !appsmith.store.fulfillment_order_detail?.progress?.can_dispatch) return null;
    if (appsmith.store.fulfillment_dispatch_busy) return null;
    await storeValue("fulfillment_dispatch_busy", true);
    try {
      // Retain this token on timeout. A retry must not create another movement.
      if (!appsmith.store.fulfillment_dispatch_reference) {
        await storeValue("fulfillment_dispatch_reference", "mp-dispatch-" + Date.now() + "-" + Math.random().toString(36).slice(2));
      }
      const result = await apiFulfillmentDispatch.run();
      if (!result || result.ok === false) throw new Error(result?.error || "Dispatch failed");
      if (id === appsmith.store.fulfillment_selected_order_id) {
        await this.refreshSelectedOrder();
        await storeValue("fulfillment_dispatch_reference", "");
        showAlert("MP dispatch committed. Payment is recorded separately.", "success");
      }
      return result;
    } finally {
      await storeValue("fulfillment_dispatch_busy", false);
    }
  },

  async recordCashReceived() {
    if (!this.selectedOrderIsCashLike() || !chkCashReceived.isChecked || appsmith.store.fulfillment_cash_busy) return null;
    const id = appsmith.store.fulfillment_selected_order_id;
    await storeValue("fulfillment_cash_busy", true);
    try {
      const result = await apiFulfillmentCashReceived.run();
      if (!result || result.ok === false) throw new Error(result?.error || "Cash receipt failed");
      if (id === appsmith.store.fulfillment_selected_order_id) {
        await this.refreshSelectedOrder();
        await resetWidget("chkCashReceived", true);
        showAlert("Cash receipt saved. ERP accounting is separately reviewed/retried.", "success");
      }
      return result;
    } finally {
      await storeValue("fulfillment_cash_busy", false);
    }
  },

  currentOperator() {
    const email = (appsmith.user?.email || "").trim().toLowerCase();
    const name = (appsmith.user?.name || "").trim();
    if (email) return email;
    if (name) return name;
    return "system";
  },

  sql: {
    str(v) {
      if (v === undefined || v === null || v === "") return "NULL";
      return "'" + String(v).replace(/'/g, "''") + "'";
    },
    num(v) {
      const n = Number(v);
      return Number.isFinite(n) ? String(n) : "NULL";
    },
    arrBigint(arr) {
      if (!arr || arr.length === 0) return "ARRAY[]::bigint[]";
      const vals = arr.map(x => {
        const n = Number(x);
        return Number.isFinite(n) ? String(n) : "NULL";
      }).filter(x => x !== "NULL");
      if (vals.length === 0) return "ARRAY[]::bigint[]";
      return "ARRAY[" + vals.join(", ") + "]::bigint[]";
    },
  },

  parseLinkedProductsFromSelectedOrder() {
    const row = appsmith.store.fulfillment_selected_order || {};

    const ids = String(row.product_ids_report || "")
      .split(",")
      .map(s => s.trim())
      .filter(Boolean);

    const names = String(row.products_report || "")
      .split(",")
      .map(s => s.trim())
      .filter(Boolean);

    const count = Math.max(ids.length, names.length);

    return Array.from({ length: count }, (_, i) => ({
      line_index: i + 1,
      product_id: ids[i] || "",
      name_mat: names[i] || "",
    }));
  },

  async clearSelectionState(resetOrderTable = false) {
    await storeValue("fulfillment_selected_order_id", "");
    await storeValue("fulfillment_selected_order", null);
    await storeValue("fulfillment_order_detail", null);
    await storeValue("fulfillment_product_results", []);
    await storeValue("fulfillment_linked_products", []);

    await resetWidget("tblFulfillmentOrderItems", true);
    await resetWidget("tblFulfillmentProducts", true);
    await resetWidget("tblFulfillmentLinkedProducts", true);
    await resetWidget("inpFulfillmentProductSearch", true);
    await resetWidget("inpManualCloverPaymentId", true);
    await resetWidget("inpManualCloverPaymentAmount", true);
    await resetWidget("inpManualCloverPaymentTime", true);
    await resetWidget("inpReconciliationNote", true);

    if (resetOrderTable) {
      await resetWidget("tblFulfillmentOrders", true);
    }
  },

  async syncLinkedProductsFromSelectedOrder() {
    const linked = this.parseLinkedProductsFromSelectedOrder();
    await storeValue("fulfillment_linked_products", linked);
    return linked;
  },

  selectedOrderProductAssignmentComplete() {
    return appsmith.store.fulfillment_order_detail?.progress?.product_assignment_complete === true;
  },

  canAssignProduct() {
    const row = appsmith.store.fulfillment_selected_order || {};
    const product = tblFulfillmentProducts.selectedRow || {};

    return !!row.airtable_record_id
      && !this.selectedOrderProductAssignmentComplete()
      && !!product.airtable_record_id;
  },

  async loadOrders() {
    const res = await apiFulfillmentListOrders.run();
    await this.clearSelectionState(true);

    if (!res || res.ok === false) {
      showAlert((res && res.error) || "Could not load fulfillment orders", "error");
      return res;
    }

    return res;
  },

  async handleOrderSelected(row = tblFulfillmentOrders.selectedRow || {}) {
    if (!row?.airtable_record_id) return null;
    if (String(row.airtable_record_id) === String(appsmith.store.fulfillment_selected_order_id)) return this.reloadOrderDetail();
    await storeValue("fulfillment_selected_order_id", row.airtable_record_id);
    await storeValue("fulfillment_selected_order", row);
    await storeValue("fulfillment_order_detail", null);
    await storeValue("fulfillment_product_results", []);
    await storeValue("fulfillment_dispatch_reference", "");
    await resetWidget("inpFulfillmentProductSearch", true);
    await resetWidget("tblFulfillmentProducts", true);
    await this.reloadOrderDetail();
    return this.searchProducts();
  },

  async reloadOrderDetail() {
    const id = appsmith.store.fulfillment_selected_order_id;
    if (!id) return null;
    const detail = await apiFulfillmentOrderDetail.run();
    if (id !== appsmith.store.fulfillment_selected_order_id) return null;
    if (!detail || detail.ok === false) throw new Error(detail?.error || "Could not reload order detail");
    await storeValue("fulfillment_order_detail", detail);
    const progress = detail.progress || {};
    await storeValue("fulfillment_selected_order", {
      ...appsmith.store.fulfillment_selected_order,
      ...progress,
      products_report: detail.products_report || "",
      product_ids_report: detail.product_ids_report || ""
    });
    await this.syncLinkedProductsFromSelectedOrder();
    return detail;
  },

  async searchProducts(page = 1) {
    const id = appsmith.store.fulfillment_selected_order_id;
    if (!id || this.selectedOrderProductAssignmentComplete()) {
      await storeValue("fulfillment_product_results", []);
      return null;
    }
    const generation = (this.searchGeneration || 0) + 1;
    this.searchGeneration = generation;
    await storeValue("fulfillment_product_page", Math.max(1, Number(page) || 1));
    const res = await apiFulfillmentProductSearch.run();
    if (id !== appsmith.store.fulfillment_selected_order_id || generation !== this.searchGeneration) return null;
    if (!res || res.ok === false) throw new Error(res?.error || "Product search failed");
    await storeValue("fulfillment_product_results", res.products || []);
    await storeValue("fulfillment_product_count", res.count || 0);
    return res;
  },

  async assignSelectedProduct() {
    if (!this.canAssignProduct() || appsmith.store.fulfillment_assign_busy) return null;
    const id = appsmith.store.fulfillment_selected_order_id;
    await storeValue("fulfillment_assign_busy", true);
    try {
      const res = await apiFulfillmentAssignProduct.run();
      if (!res || res.ok === false) throw new Error(res?.error || "Assignment failed");
      if (id !== appsmith.store.fulfillment_selected_order_id) return res;
      await this.refreshSelectedOrder();
      await resetWidget("inpFulfillmentProductSearch", true);
      await resetWidget("tblFulfillmentProducts", true);
      await storeValue("fulfillment_product_results", []);
      await storeValue("fulfillment_product_count", 0);
      showAlert(this.selectedOrderProductAssignmentComplete()
        ? "All ordered units allocated. Confirm dispatch when they leave."
        : "Product allocated. Continue scanning this order.", "success");
      return res;
    } finally {
      await storeValue("fulfillment_assign_busy", false);
    }
  },

  async handleOrderedItemSelected() {
    if (this.selectedOrderProductAssignmentComplete()) {
      await storeValue("fulfillment_product_results", []);
      return null;
    }

    return this.searchProducts();
  },

  async handleLinkedProductSelected() {
    if (this.selectedOrderProductAssignmentComplete()) {
      await storeValue("fulfillment_product_results", []);
      return null;
    }

    return this.searchProducts();
  },

  getLinkedProductsTableData() {
    if (Array.isArray(appsmith.store.fulfillment_linked_products) &&
        appsmith.store.fulfillment_linked_products.length) {
      return appsmith.store.fulfillment_linked_products;
    }

    return this.parseLinkedProductsFromSelectedOrder();
  },

  selectedOrderNeedsReconciliation() {
    const row = appsmith.store.fulfillment_selected_order || {};
    const method = String(row.payment_method || "");
    const status = String(row.payment_reconciliation_status || row.clover_reconciliation_status || row.payment_state || "").toLowerCase();
    if (!row.airtable_record_id) return false;
    if (row.can_reconcile === true) return true;
    if (row.can_reconcile === false) return false;
    return method.startsWith("Sell on the Go")
      && status !== "reconciled"
      && status !== "accounted";
  },

  selectedOrderIsCashLike() {
    const row = appsmith.store.fulfillment_selected_order || {};
    const method = String(row.payment_method || "");
    const processor = String(row.payment_processor || "").toLowerCase();
  return processor === "cash" || ["cash", "pay by cash", "pay with cash", "cash on delivery", "cod", "sell on the go - cash"].includes(method.trim().toLowerCase());
  },

  async refreshAfterReconciliation(message) {
    await this.refreshSelectedOrder();
    showAlert(message || "Reconciliation updated.", "success");
  },

  async markSelectedOrderAccounted() {
    const row = appsmith.store.fulfillment_selected_order || {};
    if (!row.airtable_record_id) {
      showAlert("Select an order first.", "warning");
      return null;
    }

    const res = await apiFulfillmentReconciliationAccounted.run();
    if (!res || res.ok === false) {
      showAlert((res && res.error) || "Could not mark order accounted.", "error");
      return res;
    }

    await this.refreshAfterReconciliation(res.message || "Order marked accounted.");
    return res;
  },

  async manualMatchSelectedOrder() {
    const row = appsmith.store.fulfillment_selected_order || {};
    if (!row.airtable_record_id) {
      showAlert("Select an order first.", "warning");
      return null;
    }
    if (!String(inpManualCloverPaymentId.text || "").trim()) {
      showAlert("Enter a processor payment ID.", "warning");
      return null;
    }
    if (!String(inpManualCloverPaymentAmount.text || "").trim()) {
      showAlert("Enter the processor payment amount.", "warning");
      return null;
    }
    if (!String(inpManualCloverPaymentTime.text || "").trim()) {
      showAlert("Enter the processor payment time, preferably ISO format.", "warning");
      return null;
    }

    const res = await apiFulfillmentManualReconciliationMatch.run();
    if (!res || res.ok === false) {
      showAlert((res && res.error) || "Manual reconciliation failed.", "error");
      return res;
    }

    await this.refreshAfterReconciliation(res.message || "Order manually reconciled.");
    return res;
  }
}