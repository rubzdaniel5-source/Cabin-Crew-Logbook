# CrewLogbook --- Dark Cockpit Theme Implementation Directive

**Purpose:** Implement the Dark Cockpit visual theme throughout the
existing CrewLogbook PWA without rebuilding the application or
disrupting working features.

## How to use this file

1.  Commit or back up the current working version before making changes.
2.  Add this file to the repository root (or keep it there if already
    present).
3.  Open Claude Code from the repository root.
4.  First ask Claude to read `CLAUDE.md`, `README.md`, and this file,
    inspect the existing codebase, and return an implementation plan
    **before editing files**.
5.  Review the plan. Then authorize Claude to implement it
    incrementally.
6.  Test locally before merging or deploying. Do not deploy
    automatically.

This file is an implementation directive. Existing repository
instructions and actual application architecture must be inspected
before changes are made.

------------------------------------------------------------------------

## 1. Objective and implementation approach

Implement a cohesive, polished **Dark Cockpit** theme across the
existing CrewLogbook PWA.

The visual direction is a professional aviation operations interface:

-   Deep navy application background.
-   Layered charcoal-blue navigation, cards, panels, and dialogs.
-   Clear white primary text and muted blue-grey secondary text.
-   Restrained aviation-gold accents for active navigation, key actions,
    selected states, and focus indicators.
-   Consistent spacing, typography, iconography, borders, and component
    behavior.
-   A clean, information-dense interface suitable for operational use on
    phones, tablets, and desktops.

This is a **visual redesign of the existing application**, not a
rewrite.

### Non-negotiable rules

-   Inspect the codebase before changing anything.
-   Read and follow `CLAUDE.md`, `README.md`, and existing project
    conventions.
-   Preserve existing routes, navigation, authentication, authorization,
    Supabase integration, database schema, data access, business logic,
    validation, offline behavior, and working features.
-   Do not replace real functionality with mock data or decorative
    placeholder buttons.
-   Do not remove, rename, or silently change a feature.
-   Do not introduce a new dependency if an existing library or project
    pattern can meet the need.
-   Do not make database migrations or alter security policies for a
    visual-only task.
-   Do not deploy, publish, or push changes unless explicitly
    authorized.
-   Do not overwrite unrelated user changes. Check Git status first and
    work safely.
-   If a requested visual change requires a functional or architectural
    change, explain the impact and ask before making that change.

## 2. Required first step: inspect and plan

Before editing, inspect:

-   Repository structure and current Git status.
-   `CLAUDE.md`, `README.md`, and other project-specific instructions.
-   Framework, build tools, CSS approach, component library, and
    existing icon library.
-   Application shell, routing, navigation, reusable components, and
    page layouts.
-   Login, registration, dashboard, New Flight, Logbook, Per Diem, and
    Crew Hub.
-   Existing Crew Hub module implementations.
-   Forms, tables, filters, dropdowns, cards, dialogs, toasts, loading
    states, empty states, and error states.
-   Supabase authentication, data access, Row Level Security (RLS),
    storage, and permissions where present.
-   PWA manifest, service worker, offline support, and install behavior.
-   Existing tests, linting, type checks, and build commands.

Then return a concise plan listing:

1.  Current styling architecture.
2.  Components and pages to update.
3.  Files likely to change.
4.  How existing functionality and security will be protected.
5.  How the implementation will be tested.
6.  Any risks or questions requiring approval.

**Wait for approval of the plan before editing files.**

## 3. Dark Cockpit design tokens

Use centralized design tokens in the styling system already used by the
project. Do not scatter unrelated color literals throughout components.

Start with these values, then check actual contrast and adjust if
needed:

  ----------------------------------------------------------------------------
  Token                        Color                   Intended use
  ---------------------------- ----------------------- -----------------------
  `--color-app-bg`             `#080F1C`               Main application
                                                       background

  `--color-nav`                `#0B1423`               Primary navigation

  `--color-header-secondary`   `#101B2B`               Secondary navigation
                                                       and header surfaces

  `--color-card`               `#172438`               Standard cards and
                                                       panels

  `--color-card-elevated`      `#1C2B40`               Hovered or elevated
                                                       cards

  `--color-input-bg`           `#101B2B`               Input and select
                                                       backgrounds

  `--color-modal-bg`           `#142238`               Dialogs and modal
                                                       surfaces

  `--color-text-primary`       `#F4F7FB`               Main text and headings

  `--color-text-secondary`     `#B3C0D1`               Supporting text

  `--color-text-muted`         `#93A3B8`               Labels and subdued
                                                       information

  `--color-text-disabled`      `#748398`               Disabled text and
                                                       controls

  `--color-accent`             `#FFC629`               Aviation-gold primary
                                                       accent

  `--color-accent-hover`       `#FFD65A`               Hover and active accent
                                                       states

  `--color-focus`              `#FFD65A`               Keyboard focus
                                                       indicator

  `--color-link`               `#8FC5FF`               Links

  `--color-border`             `#2A3A50`               Standard borders

  `--color-border-strong`      `#3A4D66`               Emphasized borders

  `--color-divider`            `#223147`               Separators

  `--color-success`            `#35C991`               Success states

  `--color-warning`            `#F5B942`               Warnings

  `--color-error`              `#FF737A`               Errors

  `--color-info`               `#72B7FF`               Informational states
  ----------------------------------------------------------------------------

Use semantic token names where the current architecture supports them.
If the project already has a token system, extend it rather than
creating a competing system.

### Color usage rules

-   Do not make every surface the same shade. Use layered surfaces to
    establish hierarchy.
-   Avoid using pure black as the background for every element.
-   Use gold selectively. Large gold panels or gold body text should not
    dominate the interface.
-   Do not use color alone to communicate a warning, status, error, or
    success.
-   Verify text and control contrast after implementation; the initial
    palette is a starting point, not proof of accessibility.

## 4. Global visual system

Apply the theme consistently across the application.

### Typography

-   Use the existing font unless there is a strong reason to change it.
-   Establish consistent heading, body, label, helper-text, and numeric
    styles.
-   Keep important operational values easy to scan.
-   Avoid excessive bold text, all-caps labels, and inconsistent font
    sizes.

### Spacing and layout

-   Establish a consistent spacing scale and card padding.
-   Align headings, actions, fields, and card edges.
-   Use consistent corner radii and border weights.
-   Use shadows sparingly; rely primarily on surface contrast and
    borders.
-   Ensure information density is appropriate for an operational crew
    application.
-   Avoid unnecessary decorative gradients, glass effects, and
    animation.

### Reusable components

Where feasible, standardize the appearance and behavior of:

-   Primary, secondary, destructive, and disabled buttons.
-   Text fields, text areas, selects, checkboxes, and radio controls.
-   Cards, KPI panels, tables, badges, tabs, and navigation.
-   Dropdowns, date/time controls, tooltips, and search.
-   Dialogs, confirmation prompts, toasts, banners, and notifications.
-   Loading indicators, skeletons, empty states, and error states.

Do not perform a large component rewrite just to make styling uniform.
Reuse existing components when practical.

## 5. Navigation and application shell

Preserve the current destinations and their behavior:

-   Dashboard
-   New Flight
-   Logbook
-   Per Diem
-   Crew Hub

Style the application shell consistently:

-   Deep-navy primary navigation.
-   A clear and accessible active-tab state using aviation gold and an
    appropriate text/icon treatment.
-   Consistent spacing and alignment across navigation items.
-   Consistent line icons from the icon library already installed in the
    project.
-   Clear page titles and actions.
-   Responsive behavior that fits the existing application and does not
    hide essential navigation unexpectedly.

Do not change route names, route guards, or navigation logic for styling
purposes.

## 6. Crew Hub redesign

Keep all existing Crew Hub features and their current functionality.
Present the following modules in a consistent card grid:

1.  **Onboard Announcements** --- Approved onboard announcement
    resources.
2.  **Nexa Crew AI** --- AI assistant for manuals and operational
    documents.
3.  **Passenger Manifest** --- View or upload flight manifests.
4.  **Purser Flight Report** --- Draft and submit flight reports.
5.  **Manuals** --- Access crew and operations manuals.
6.  **Cabin Log** --- Record and track cabin defects.
7.  **Crew Chat** --- Group and private messaging.
8.  **IQSMS** --- Access existing safety-reporting functionality.
9.  **Cabin Notices** --- Operational notices and bulletins.
10. **Passenger Feedback** --- Access passenger experience reports and
    ratings.

The descriptions above are visual guidance only. Inspect the existing
application and retain the real feature names, permissions, actions, and
data behavior wherever they differ. Do not invent capabilities that are
not implemented.

### Card design

-   Use the standard card surface and border tokens.
-   Provide a consistent icon area, module title, and short description
    if descriptions fit the existing UX.
-   Use a consistent alignment, padding, and spacing system.
-   Use a subtle hover/focus state, not a large animation.
-   Keep text readable and cards easy to tap on mobile.
-   Use a responsive two-column grid where the viewport allows it, then
    adapt to narrower screens without horizontal overflow.
-   Preserve existing status indicators only when they are backed by
    real data.
-   Do not add fake counts, unread badges, availability labels, or
    status values.

### Icons

Replace emoji icons with a consistent icon set **if** the project
already has a suitable icon library. Do not install a new package
without checking first.

If the installed library is Lucide or an equivalent, choose appropriate
consistent line icons, such as:

-   Onboard Announcements: `megaphone`
-   Nexa Crew AI: `bot`
-   Passenger Manifest: `clipboard-list`
-   Purser Flight Report: `file-text`
-   Manuals: `book-open`
-   Cabin Log: `wrench`
-   Crew Chat: `messages-square`
-   IQSMS: `shield-check`
-   Cabin Notices: `pin`
-   Passenger Feedback: `message-square-text`

Use the actual names supported by the installed icon library. Keep icon
sizes, stroke weights, and alignment consistent. Icons must not replace
accessible text labels.

### Floating action button

Inspect the existing floating plus (`+`) button and identify what it
actually does.

-   If it has an existing valid purpose, preserve the action and restyle
    it consistently.
-   If its purpose is unclear, report that to me before changing its
    behavior.
-   Do not invent a new action or make the button decorative.
-   Ensure it does not obscure content or interfere with mobile safe
    areas.

## 7. Apply the theme throughout the app

Do not stop after updating Crew Hub. Audit and style all existing
screens and states, as applicable:

-   Login and registration.
-   Dashboard and any KPI cards.
-   New Flight and flight-entry forms.
-   Logbook, flight records, filters, and tables.
-   Per Diem.
-   Crew Hub and its module entry points.
-   Manuals and document viewers.
-   Profile and account settings.
-   Admin and announcement screens.
-   Search, dropdowns, date/time pickers, and confirmation dialogs.
-   Loading, empty, offline, validation-error, and success states.

Do not create new screens just because they appear in this list. Only
update screens and components that exist in the repository.

## 8. Forms, tables, and operational data

Operational data must remain easy to read and interact with.

-   Ensure input labels, placeholders, helper text, errors, and disabled
    states remain distinguishable.
-   Keep table headers, rows, separators, and selected rows legible.
-   Make status badges readable and do not rely on color alone.
-   Preserve date, time, numeric, and aviation-specific data formats
    already used by the application.
-   Maintain existing validation, required-field behavior, and error
    handling.
-   Do not alter form submission logic, database writes, or data models
    to accomplish the redesign.

## 9. Responsive design and PWA

Test the interface at these viewport widths where possible:

-   320 px
-   375 px
-   390 px
-   768 px
-   1024 px
-   1440 px

Check that:

-   There is no unintended horizontal scrolling.
-   Cards and forms resize appropriately.
-   Buttons and touch targets are usable on mobile.
-   Dialogs fit the viewport and remain scrollable where necessary.
-   Navigation remains usable.
-   Floating controls respect device safe areas.
-   Long names, flight numbers, labels, and descriptions do not break
    layouts.
-   The existing installable PWA behavior remains intact.

If appropriate, update browser/status-bar theme colors in the PWA
manifest or existing metadata so they complement Dark Cockpit. Do not
change service-worker caching or offline architecture for a visual-only
redesign unless a change is demonstrably necessary and separately
approved.

## 10. Accessibility requirements

Target WCAG 2.2 AA for the updated interface where applicable.

-   Aim for a contrast ratio of at least 4.5:1 for normal text and 3:1
    for large text.
-   Check text, icons, borders, controls, focus indicators, and status
    labels.
-   Provide a visible keyboard-focus state.
-   Preserve semantic HTML and logical heading order.
-   Ensure form controls have accessible labels.
-   Maintain keyboard operation for navigation, menus, dialogs, and
    actions.
-   Do not use color as the sole indicator of status.
-   Respect reduced-motion preferences and avoid unnecessary animation.
-   Do not remove accessible names when replacing icons or styling
    buttons.

Use automated checks if available, but do not claim full accessibility
compliance solely because an automated tool reports no issues.

## 11. Security and data integrity

This is an airline operational application. A visual redesign must not
weaken security or data integrity.

-   Preserve authentication and session handling.
-   Preserve role-based access control and Supabase Row Level Security
    policies.
-   Preserve private storage and document access restrictions.
-   Preserve server-side or database-side permission enforcement.
-   Do not expose passenger, crew, flight, or document data through new
    UI states, debug logs, or client-side shortcuts.
-   Hiding a button is not an authorization control.
-   Do not change data retention, offline storage, or synchronization
    behavior as part of this visual task.
-   If an existing security issue is discovered, report it separately
    rather than silently expanding the task.

## 12. Implementation and testing sequence

Implement incrementally:

1.  Record the initial Git status and inspect the current styling
    system.
2.  Add or refine centralized design tokens.
3.  Update global typography, backgrounds, and application surfaces.
4.  Update the shared navigation and application shell.
5.  Update reusable components.
6.  Update Crew Hub cards and icons.
7.  Apply consistent styles to remaining existing screens.
8.  Review responsive layouts and accessibility.
9.  Run the project's available lint, type-check, test, and
    production-build commands.
10. Manually test key navigation and workflows where the environment
    allows it.
11. Review the final Git diff for accidental functional changes.

If the project has a test environment, verify that the following still
work:

-   Login and logout.
-   Navigation to each main section.
-   Creating or opening a flight record.
-   Existing Logbook and Per Diem interactions.
-   Opening each Crew Hub module.
-   Existing forms and validation.
-   Existing document and manual access.
-   Existing online/offline behavior, to the extent testable.

Do not fabricate test results. Clearly distinguish checks that passed,
failed, were skipped, or could not be run.

## 13. Completion report

When implementation is complete, provide:

1.  Summary of the visual changes.
2.  Files changed and why.
3.  Design tokens added or updated.
4.  Pages and shared components updated.
5.  Confirmation of the important existing behaviors preserved, based on
    actual inspection/testing.
6.  Commands and tests run, with real outcomes.
7.  Any visual or functional issues that remain.
8.  Any manual checks I should perform.
9.  A suggested commit message.

Do not deploy or publish the application unless I explicitly authorize
it.

## 14. Acceptance criteria

The work is ready for review when:

-   Dark Cockpit is consistently applied across existing screens, not
    just Crew Hub.
-   The interface looks like one cohesive aviation product rather than a
    collection of unrelated cards.
-   The navy, layered blue-grey, white text, and restrained gold palette
    is used consistently.
-   Icons, spacing, typography, borders, buttons, cards, forms, and
    dialogs are consistent.
-   The Crew Hub retains all ten modules and their existing behavior.
-   The layout works at mobile, tablet, and desktop widths without
    unintended overflow.
-   Contrast and keyboard focus have been checked.
-   Existing authentication, permissions, database behavior, offline
    behavior, and routing have not been intentionally changed.
-   Available tests and the production build have been run and honestly
    reported.
-   No deployment has occurred without approval.

**Final instruction:** Work with the existing CrewLogbook codebase.
Prefer small, reviewable changes over a rewrite. If the repository
structure or current implementation conflicts with any part of this
directive, explain the conflict and propose the safest adaptation before
proceeding.
