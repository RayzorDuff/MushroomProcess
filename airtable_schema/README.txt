Export

Install airtable-export according to https://pypi.org/project/airtable-export/

export AIRTABLE_KEY=xxx # Your airtable key
export AIRTABLE_BASE=yyy # Your airtable base

airtable-export export $AIRTABLE_BASE strains recipes products lots items events locations sterilization_runs print_queue  \
    --ndjson --yaml --json --sqlite mushroomprocess.db

Import

TBD
