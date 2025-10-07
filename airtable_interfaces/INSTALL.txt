INSTALL – Set up a fresh Airtable base

1) Create Interfaces:
   - Follow the “Mushroom Process_Interfaces.pdf” for page-by-page setup.

2) Add Automations (one per flow):
   - For each JS file in /automations, create an Airtable Automation:
     - Trigger: usually a button “Run a script” on the relevant table (pass current record ID as input).
     - Paste the JS code into the Script action.
     - Ensure field names match your base (adjust if you renamed).

Notes:
- Keep `ui_error` visible in all Interfaces so users see validation messages from scripts.
- If any field names differ, update the corresponding script constants.