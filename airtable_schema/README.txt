Export

Install airtable-export according to https://pypi.org/project/airtable-export/

Determine where your Python is installed.
# py -c "import sys; print(sys.prefix)"
C:\Python313

Update your Powershell profile
# notepad $PROFILE

# Add your specific airtable base and key
$env:AIRTABLE_KEY = "patyyy"
$env:AIRTABLE_BASE = "appxxxx"
$env:PATH += "C:\Python313;C:\Python313\Scripts;$Env:APPDATA\Python\Python313\Scripts"

airtable-export export $Env:AIRTABLE_BASE strains recipes products lots items events locations sterilization_runs print_queue --ndjson --yaml --json --sqlite export\mushroomprocess.db

Import

TBD
