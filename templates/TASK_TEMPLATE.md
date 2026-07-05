# TASK-XXX: Short Task Summary
<!-- Reference the main Epic or issue here, e.g. [[Epic-Name]] -->

## Scope
<!-- Define paths of files that the Worker is allowed to EDIT. Relative to project root. -->
- path/to/file1.ext
- path/to/file2.ext

## Context
<!-- OPTIONAL: Reference files that the Worker should read but is NOT allowed to edit. Relative to project root. -->
- path/to/reference_file.ext

## Invariants
<!-- Critical safety conditions that MUST be preserved at all times -->
- DB query must filter by tenantId
- Input parameters must be validated

## Forbidden
<!-- Patterns that are strictly banned in edits for this specific task -->
- No raw SQL
- Do not skip tests

## DoD (Definition of Done)
<!-- Specific criteria required to consider the task complete -->
- Unit tests pass
- ESLint checks pass without warnings
