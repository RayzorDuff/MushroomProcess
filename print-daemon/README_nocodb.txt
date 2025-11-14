DONE:
Pulls print jobs from NocoDB instead of Airtable
Updates print_status, error_msg, and pdf_path in NocoDB instead of Airtable

TODO:
Still uses Airtable for sterilizer runs / lots (for the Steri Sheet), to be migrated later.


New env vars for NocoDB

Add these to your .env:

NOCODB_URL=http://your-nocodb-host  # e.g. http://localhost:8080
NOCODB_API_TOKEN=your_api_token     # NocoDB API token
NOCODB_QUEUE_TABLE_ID=print_queue   # or the table UUID/slug for your print_queue
