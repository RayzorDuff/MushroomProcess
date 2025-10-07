INSTALL – Set up a fresh Airtable base

1) Add Automations (one per flow):
   - For each JS file in /airtable_automations, create an Airtable Automation:
     - Trigger: usually a button “Run a script” on the relevant table (pass current record ID as input).
     - Paste the JS code into the Script action.
     - Ensure field names match your base (adjust if you renamed).
