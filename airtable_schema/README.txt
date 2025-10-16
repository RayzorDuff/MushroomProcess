Export

Install airtable-export from git main, not pip

git clone https://github.com/simonw/airtable-export.git

python -m pip install --user pipx
python -m pipx ensurepath
pip cache purge
pip uninstall airtable-export
pip install -e airtable-export

Determine where your Python is installed.
# py -c "import sys; print(sys.prefix)"
C:\Python313

Update your Powershell profile
# notepad $PROFILE

# Add your specific airtable base and key
$env:AIRTABLE_KEY = "patyyy"
$env:AIRTABLE_BASE = "appxxxx"
$env:PATH += "C:\Python313;C:\Python313\Scripts;$Env:APPDATA\Python\Python313\Scripts"

airtable-export -schema --ndjson --yaml --json --sqlite export\mushroomprocess.db export $Env:AIRTABLE_BASE strains recipes products lots items events locations sterilization_runs print_queue 

Import

TBD
