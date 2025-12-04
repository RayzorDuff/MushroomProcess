# Airtable Interfaces

This folder documents the **Airtable Interfaces** used by operators at each station (Sterilizer, Dark Room, Fruiting, Packaging, etc.).

It includes:

- `Mushroom Process_Interfaces.pdf` – primary, page-by-page visual guide.
- `Interface_*.txt` – notes for each interface view.

Interfaces sit on top of the same base schema and automations described elsewhere in this repo.

---

## 1. Interfaces Overview

Each station gets one or more Interfaces that:

- Show only the records relevant to that station (e.g., current sterilization runs, dark room lots, harvest-ready blocks).
- Provide buttons that trigger the automations in `airtable_automation/`.
- Surface errors through a `ui_error` field so operators know what went wrong (invalid state, missing links, etc.).

---

## 2. Installation – Set Up Interfaces in a Fresh Base

1. **Base and schema first**

   - Ensure your Airtable base already has:
     - The MushroomProcess tables and fields (`airtable_schema/`).
     - The automations from `airtable_automation/` installed and tested.

2. **Create Interfaces**

   - Open `Mushroom Process_Interfaces.pdf`.
   - For each interface described:
     1. Go to **Interfaces** in Airtable.
     2. Create a **new Interface** (layout and page types as shown in the PDF).
     3. Add views, filters, and grouped layouts to match the screenshots and notes.
     4. Link buttons in the interface to the corresponding automations (or directly to button fields that trigger those automations).

3. **Automation hooks**

   - For each JS file in `/airtable_automation`, ensure there is a corresponding Automation wired to the correct button fields used in the interface.

4. **Expose `ui_error` in all interfaces**

   - Make sure each interface layout includes the `ui_error` field (or equivalent).
   - Scripts write validation messages here so operators see issues immediately.

---

## 3. Notes & Tips

- If you rename fields or tables, update:
  - The **Airtable interfaces** (filters, labels, controls).
  - The **automation scripts** that reference those fields.
- For complex flows (e.g., Spawn to bulk), cross-check:
  - The PDF diagrams
  - The events written in your `events` table
  - The audit trails in your automations

With this folder plus the PDF, you can reconstruct the operator-facing Airtable experience from scratch.
