# Personnel Reviews and 10-Minute Manager Log

## Purpose

This document defines a lightweight personnel-review workflow for MushroomProcess using a Postgres-backed manager log and an Appsmith entry page.

The goal is to reduce recency bias and review-period bias by capturing short, factual performance observations throughout the review period rather than reconstructing performance from memory alone.

## Rationale

Traditional reviews often overweight recent events and the reviewer’s current impression of the employee. A better approach is to record observations as they occur, including both strengths and coaching opportunities.

This implementation follows the spirit of the "10-minute manager log" model:

- short entries
- captured close to the event
- behavior-based
- usable later for balanced review summaries
- suitable for upward feedback and self-review expansion later

## Design Principles

- Keep entry friction low enough that the log is actually used
- Record both positive and corrective observations
- Focus on observable behavior, context, and impact
- Separate personnel review data from production workflow data
- Read from views in Appsmith
- Write through canonical Postgres functions
- Defer reporting complexity until the next review cycle

## Initial Scope

Initial scope is limited to single-entry capture for manager notes.

The first implementation includes:

- personnel review subject table
- personnel review entry table
- canonical insert function
- simple Appsmith page for one-at-a-time log entry
- recent-entry display for context

Deferred scope:

- review-cycle rollups
- review packet generation
- acknowledgment workflow
- employee self-review UI
- upward feedback UI
- peer review UI
- notifications / follow-up reminders

## Data Model

### personnel_review_subjects

Represents the person being reviewed.

Core fields:

- subject_code
- full_name
- active
- role_title
- supervisor_name
- hire_date
- notes

### personnel_review_entries

Represents one ad hoc observation or review-related note.

Core fields:

- subject_id
- entry_ts
- observed_on
- entered_by
- entry_source
- note_type
- category
- visibility
- summary
- details
- follow_up_needed
- follow_up_by
- related_review_period_start
- related_review_period_end
- tags

## Entry Types

Recommended use of `note_type`:

- `positive`: notable strength or good performance
- `coaching`: corrective guidance or developmental feedback
- `neutral`: factual note without clear positive/negative weighting
- `concern`: issue requiring attention
- `accomplishment`: concrete milestone or success
- `goal`: development target or future objective
- `review_prep`: note created while assembling formal review
- `upward_feedback`: employee feedback about supervisor

## Categories

Recommended categories:

- quality
- productivity
- reliability
- communication
- teamwork
- initiative
- leadership
- attendance
- training
- safety
- judgment
- professionalism
- other

## Guidance for Writing Entries

Entries should be:

- specific
- factual
- behavior-based
- short enough to be sustainable
- detailed enough to be useful later

Prefer:

> Completed packaging reconciliation accurately and flagged the discrepancy before shipment.

Avoid:

> Great worker.

Prefer:

> Missed the sanitation checklist step on 2026-03-01; issue was corrected after coaching and checklist was re-run.

Avoid:

> Careless.

A good entry usually includes:

1. what happened
2. when it happened
3. why it mattered
4. whether coaching or follow-up occurred

## Visibility

Visibility supports future review workflow:

- `manager_only`: private notes not intended for direct sharing
- `shared_at_review`: review-period discussion item
- `shared_immediately`: feedback intended to be discussed promptly

## Recommended Operating Practice

### Cadence

Managers should record short entries on an ongoing basis, ideally within 24 hours of the event.

### Balance

Log both positive and corrective observations. A useful practice is to avoid allowing the log to become purely disciplinary.

### Review Preparation

At review time:

1. filter entries for the review period
2. group by category
3. identify repeated strengths
4. identify repeated growth areas
5. distinguish pattern from isolated incident
6. incorporate employee self-review
7. incorporate upward feedback where appropriate
8. write a summary based on evidence in the log

## Immediate Review Workflow

For a review that must be produced before the log is fully populated:

1. reconstruct the last 6 months from memory, records, and milestones
2. ask the employee for a self-review
3. request feedback for the supervisor
4. write the review using specific examples
5. begin continuous logging immediately after the review

## Appsmith Page Intent

The initial Appsmith page is intentionally simple:

- choose employee
- choose note type
- choose category
- enter summary
- enter optional detail
- set follow-up if needed
- save

The page should also display recent entries for the selected employee.

## Future Extensions

Likely next steps:

- review-cycle reporting page
- follow-up due list
- acknowledgment tracking
- employee self-review form
- upward feedback entry form
- structured goal-setting and review-period closeout