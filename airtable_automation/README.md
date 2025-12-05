# Airtable Automations

This folder contains the **Airtable Automation scripts** that power the MushroomProcess workflows:

- Sterilizer IN / OUT
- Liquid culture → grain
- Grain → substrate
- Spawn to bulk
- Harvest, packaging, labeling
- Validation and audit-logging Events

Each script is intended to run as an Airtable **Automation Script action** triggered by a button or by record changes.

---

## Files

Typical script types you’ll see here:

- `*_create_lots.js` – create new records in `lots` and link input/output items.
- `*_validate_*.js` – validate user input, write to `ui_error`, and prevent bad transitions.
- `*_actions.js` – encapsulate a full workflow (e.g., Sterilizer out, Spawn to bulk, Dark Room actions).

Script names match the station / workflow names used in Interfaces.

---

## Installation – Set Up a Fresh Airtable Base

1. **Confirm your Airtable base and fields**

   - Your base should already have the MushroomProcess schema (see `airtable_schema/`).
   - Ensure tables and fields (especially linked records and `ui_error`) match the scripts’ expectations.

2. **Create one Automation per flow**

   For each `*.js` file in this folder:

   1. In Airtable, go to **Automations → Create automation**.
   2. Choose a trigger appropriate for that flow, commonly:
      - A **button field** (“Run script”, “Sterilizer OUT”, “Spawn to bulk”, etc.) that:
        - Runs an Automation and passes the current record’s ID (often via an input variable).
      - Or a record-change trigger if that fits the workflow better.
   3. Add an **“Run script”** action.
   4. Paste the contents of the corresponding `.js` file into the script editor.
   5. Map any input variables (e.g., `recordId`) based on the trigger.

3. **Adjust field & table names if needed**

   - If your Airtable base uses different field names than the original schema:
     - Update constants at the top of each script (e.g., `TABLE_LOTS`, `FIELD_STATUS`, etc.).
     - Keep `ui_error` (or your equivalent field) visible in Interfaces so operators see validation messages.

4. **Test each automation**

   - Use a small, disposable set of test records to run each button/flow.
   - Verify:
     - New lots / events are created correctly.
     - Status fields and links are updated.
     - Label requests land in the `print_queue`.

Once this is complete, your Airtable base will have the same behavioral layer as the original production MushroomProcess system.
