# MushroomProcess 
# – Airtable Inventory & Labeling System

This project implements a production-grade inventory, traceability, and label-printing system for a mushroom cultivation business.
It is built on Airtable with mobile-friendly Interfaces for each station (sterilizer, inoculation, dark room, fruiting, harvest, packaging),
and integrates with a Node-based print daemon to output 4×2 thermal labels (JADENS JD268BT-CA).

## Components
- Airtable base with tables: items, recipes, strains, locations, sterilization_runs, lots, events, products, print_queue.
- Station-specific Interfaces with validation and audit Events.
- Automation scripts (JavaScript) for every core workflow.
- Print queue that feeds your Node print daemon for automatic label generation.

## Getting Started
See `*/INSTALL.txt` for detailed setup steps, including how to import the schema, wire the automation scripts, and configure the Interfaces and printing.