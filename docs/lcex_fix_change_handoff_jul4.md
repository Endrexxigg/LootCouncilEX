# LCEX Fix / Change Handoff

## Context

LCEX is a WoW Classic/TBC Anniversary loot council addon. This handoff is focused on practical fixes and UX improvements, not a broad redesign.

The agent should preserve existing intended LCEX behavior unless a listed issue explicitly changes it. In particular, LCEX should continue treating the active loot session and the visible session window as separate concepts: hiding/minimizing the window must not end the session.

## Global Rules / Constraints

- Target client: **TBC Classic Anniversary**.
- Keep scope tight: fix the listed issues without “creatively” redesigning unrelated systems.
- Match existing LCEX patterns where they make sense, but clean up obviously broken UI/behavior.
- Do not destroy active session state on `/reload`, disconnect, temporary group drop/rejoin, or window close.
- Add recovery/resume behavior where needed rather than silently deleting session data.
- Non-council raid members should have limited loot visibility by default, but should not see council/private voting details.

---

## 1. Loot Frame Visibility Model

### Problem

Non-council raid members should be able to check what dropped and who received items without seeing the full council/ML decision-making frame.

Currently, visibility needs a clearer default model.

### Desired Default Behavior

By default, everyone in the raid should be able to see the **left-side loot pane/list pane only**.

This should be similar to what the master looter/council sees before a session starts:

- List of session items / dropped loot.
- Item icons and item names.
- Quantity where applicable.
- Award state where applicable.
- Who won an item once awarded.
- Basic public loot/session information.

Non-council members should **not** see the expanded/full frame by default.

The expanded/full frame should remain restricted to council/ML users and should include private or decision-making details such as:

- Other players’ responses.
- Votes.
- Council-only deliberation information.
- Any other council review/details UI.

Council members may see the expanded review/voting frame, but award/end/override controls remain master-looter-only and should be hidden or disabled for non-ML council members.

Default non-council visibility should hide other players’ responses, council votes, award controls, council comments, internal deliberation metadata, and private notes/details.

Non-council members should not see the expanded council frame, but they still need access to their own response flow when an item is up for response. Responses are submitted through the **POLL frame**. That flow should expose only the player’s own response controls, not other players’ responses, votes, or council details.

### Acceptance Criteria

- Non-council members can open/view the loot pane if they want to check drops or award results.
- Non-council members only see the left list pane by default.
- Council and ML can access the expanded frame with responses/votes/etc.
- Non-council users cannot see private voting/deliberation details by default.
- Award/control actions remain permission-gated.
- Raiders can still submit their own responses through the **POLL frame**.

---

## 2. Loot Session Frame: Voting Button Order

### Problem

The voting buttons are visually reversed. The plus button appears on the left and minus on the right.

### Desired Behavior

Display voting buttons as:

```text
[-] [+]
```

not:

```text
[+] [-]
```

### Acceptance Criteria

- Negative/downvote button is left.
- Positive/upvote button is right.
- Layout reads consistently wherever voting buttons appear.

---

## 3. Loot Session Frame: Award Feedback and Correction

### Problem

After an item is awarded, the loot frame does not clearly show that the item has been awarded.

### Desired Behavior

Once an item is awarded:

- The award button should grey out or become disabled.
- The awarded player should be clearly marked.
- The item row/session state should clearly indicate that the item is already awarded.
- There should be a deliberate correction path for accidental awards.

### Award Correction / Override

The master looter should have a simple correction path for mistakes, most commonly used immediately after a bad award, such as:

- Awarded to wrong person.
- Someone says “wait.”
- ML clicked the wrong row.
- The decision changed before the physical trade happened.

Suggested interaction:

- Right-click the awarded player/name or awarded row to expose a correction/override action.

This should not feel like a whole separate complex workflow. It should be a simple “correct this award” escape hatch.

LCEX should also allow correcting the recorded award state later for edge cases, even after the physical trade happened. In that case, LCEX is only correcting its own record/history; it should not imply that the in-game item transfer was reversed.

Only the master looter can perform award correction/override.

### Acceptance Criteria

- Awarded items are visually distinct.
- Award button cannot be casually clicked again after award.
- Master looter has a clear but intentional way to correct mistakes.
- Non-master-looters cannot override awards.
- Post-trade correction is treated as record correction only.

---

## 4. Loot Session Frame: Compact Pre-Session State

### Problem

Before a session starts, the frame opens full-size even though the response/detail area has nothing useful to show.

### Desired Behavior

Before a session starts:

- Show only the session items list / pre-session item setup area.
- Hide the large response/detail panel.

Once a session starts:

- Expand into the full loot session frame.
- Show item details, response rows, voting, award controls, etc.

### Acceptance Criteria

- Pre-session window is compact.
- Full session UI appears only once there is an active session.
- No empty/dead right-side panel is shown before the session begins.

---

## 5. Loot Session Frame: Mini / Minimized Mode

### Problem

The full session frame can block gameplay. In RCLC, closing the frame can effectively abort/disrupt the session. LCEX should improve on this.

### Desired Behavior

Add a small draggable mini frame for active sessions.

The mini frame should:

- Indicate that a loot session is active.
- Allow reopening/expanding the full session frame.
- Allow the full session frame to be hidden without ending the session.
- Support collecting responses now and awarding later.

### Use Case

During SSC, the guild may put loot up while running from Leotheras to Lady Vashj, collect responses during the run, then defer actual deliberation/awards until later.

### Acceptance Criteria

- Closing/minimizing the full frame does not end the session.
- Responses continue to be captured.
- Master looter can return later and award items.
- Session visibility and session state remain separate concepts.
- Mini frame is draggable and unobtrusive.

---

## 6. Session Persistence / Recovery

### Problem

LCEX should support deferred loot decisions without leaving unsafe zombie sessions or losing important state.

### Desired Behavior

Active sessions should persist until explicitly completed/aborted by the master looter.

Do **not** automatically destroy a session because of:

- `/reload`
- Disconnect
- Temporary group drop/rejoin
- Window close/minimize

These events can be treated as signals/warnings, but not deletion triggers.

### Suggested Behavior

- On reload/login/rejoin, detect unresolved session state and offer to resume.
- If the player is no longer master looter or no longer in the relevant raid, show a safe read-only/recovery state instead of silently deleting data.
- Show age/status for unresolved sessions so the ML can tell whether they are resuming something recent or stale.
- Resuming an unresolved session after reload/reconnect should restore local/session state safely and should not accidentally rebroadcast, restart, or duplicate the session unless the ML explicitly takes that action.
- Add explicit master-looter-only **End Session** / **Abort Session** actions.

### Acceptance Criteria

- No session data loss from reload/disconnect.
- Active unresolved sessions can be resumed.
- Stale/unresolved sessions are labeled clearly with age/status.
- Explicit end/abort action exists.
- Session cleanup is conservative and safe.
- Resume/recovery does not accidentally rebroadcast, restart, or duplicate old sessions.

---

## 7. Gargul-Style Loot Trade Timers

### Problem

LCEX needs loot trade timer support.

### Desired Behavior

Add loot trade timers modeled very closely after **Gargul**, the WoW Classic loot addon.

Target Gargul behavior as closely as practical:

- Compact draggable mini window.
- Expand/collapse behavior.
- Clear trade timer display for tradeable loot.
- Usable during and after loot sessions.

### Agent Task

Inspect Gargul’s current loot trade timer UX and reproduce the behavior pattern in LCEX as closely as practical without directly copying code.

### Acceptance Criteria

- Trade timers are easy to monitor at a glance.
- Mini window is movable.
- Expand/collapse behavior feels similar to Gargul.
- Timer behavior works cleanly with active/deferred LCEX sessions.

---

## 8. Shared Row/List Readability Styling

### Problem

Long row lists are hard to read because adjacent rows visually blend together.

### Desired Behavior

Apply alternating light/dark row backgrounds to long list-style rows across the addon, including:

- Loot session respondent rows.
- Roster frame rows.
- Loot browser / loot tab rows.
- Other similar long row lists where readability suffers.

### Acceptance Criteria

- Adjacent rows are visually distinct.
- Styling is subtle but clearly improves scanability.
- Implementation is reusable/shared where practical instead of duplicated ad hoc.

---

## 9. Loot Session Item List: Broken Awarded/Winner Glyph

### Problem

In the left-side loot session item list, once an item is awarded, the winner’s name appears with a broken Unicode/error glyph in green.

This is likely intended to be a checkmark or awarded indicator.

### Desired Behavior

Replace the broken glyph with a valid visual indicator, such as:

- A working checkmark icon/glyph.
- A small clean awarded icon.
- Another clear awarded-state marker.

### Acceptance Criteria

- No broken Unicode/error glyph appears.
- Awarded item rows clearly show the winner.
- Awarded indicator is visually clean.

---

## 10. Loot Session Item List: Quantity Display and Duplicate Handling

### Problem

Each item currently appears to show a quantity/count of `1`. This is noisy because quantity 1 is the default.

### Desired Behavior

- Hide quantity when quantity is 1.
- Group duplicate items visually where safe.
- Show multiples with a clear quantity tag like `x2`, `x3`, etc.
- Make quantity tags obvious/high-contrast, not dim grey.
- This is especially important for duplicate token drops.

### Important Implementation Note

Duplicate item grouping must preserve per-item instance tracking internally.

Even if two items are grouped visually, LCEX may still need to track each physical item separately because each copy could have:

- A different trade timer.
- A different winner.
- A different award state.
- A different bag slot/item instance.

If duplicate copies have different winners, award states, trade timers, or bag instances, the UI must provide a way to distinguish them instead of hiding meaningful differences behind a single `x2` row.

### Acceptance Criteria

- Single items do not show unnecessary `1`.
- Duplicate items are grouped or clearly represented.
- Multiples are shown as `x2`, `x3`, etc.
- Quantity indicator is easy to see.
- Internal per-item tracking is not broken by visual grouping.
- Duplicate rows remain distinguishable once their state diverges.

---

## 11. Loot Session Item List: Item Name Truncation

### Problem

Item names in the left-side session items list are being truncated too aggressively.

### Desired Behavior

Improve the layout so item names are easier to read.

Possible fixes:

- Slightly widen the left session item list.
- Adjust columns/padding.
- Reduce wasted space.
- Add tooltip fallback if needed.

### Note

Do **not** broadly add tooltip-on-name behavior to the left-side session items list unless needed. Tooltip-on-name is more important in the loot browser and selected item display.

### Acceptance Criteria

- Common item names are readable.
- Truncation is reduced.
- Layout still fits the overall frame.

---

## 12. Loot Session Item List: Scrollbar Position

### Problem

The scrollbar for the left-side session item list is positioned outside the list area, on the wrong side of the divider/margin.

### Desired Behavior

Keep the scrollbar on the right edge of the left-side item list, but move it inside that panel, immediately before the divider.

### Acceptance Criteria

- Scrollbar is visually part of the left item list.
- Scrollbar is not outside the panel or across the divider.
- Positioning matches the intended list bounds.

---

## 13. Loot Browser: Collapsible Raid and Boss Categories

### Problem

The loot browser is hard to use when all raids, bosses, and items are expanded at once.

### Desired Behavior

Add collapsible hierarchy:

- Raid categories collapse/expand.
- Boss categories collapse/expand.
- Items display under their boss when expanded.

### Acceptance Criteria

- Users can collapse entire raids.
- Users can collapse individual bosses.
- Collapsed state improves navigation and scanability.

---

## 14. Loot Browser: Stronger Note Indicators

### Problem

Items with notes are not obvious enough while scanning the loot browser.

### Desired Behavior

If an item has a user note, the row should have a clear visual indicator.

User notes / council notes should not appear in the public left-side raid loot pane unless explicitly intended elsewhere.

Possible indicators:

- Highlight.
- Icon.
- Badge.
- Colored marker.

### Acceptance Criteria

- Items with notes are obvious at a glance.
- Indicator does not get confused with item quality color.
- Indicator only reflects actual user notes.
- Notes are not exposed in the public left-side raid loot pane by default.

---

## 15. Loot Browser: Tooltip on Item Name Hover

### Problem

In the loot browser, item tooltip only appears when hovering the item icon.

### Desired Behavior

In the loot browser, show item tooltip when hovering:

- Item icon.
- Item name text.

Also apply this behavior to other council/loot-management item names where useful, especially:

- The large selected item display at the top of the loot session/detail frame.

This behavior is **not required** for the left-side session items list.

### Acceptance Criteria

- Loot browser item names show tooltip on hover.
- Large selected item display shows tooltip on hover.
- Behavior is not over-applied where it adds clutter or conflicts with list interactions.

---

## 16. Loot Browser: Token Text Showing as Note

### Problem

In the loot browser right-side notes area, tier tokens are showing `(Token)` as if it were a user note.

This is confusing.

### Desired Behavior

- Do not display `(Token)` in the notes area.
- Do not show `Token` elsewhere as metadata unless there is a clear future reason.
- The notes area should show only actual user-entered notes.

### Acceptance Criteria

- Tier tokens no longer show `(Token)` as a note.
- Notes area contains only real notes.
- No confusing fake/system notes appear.

---

## 17. Loot Browser: Replace Always-Visible Note Textbox

### Problem

The current note UI is clunky. A permanent text box at the bottom of the frame looks bad and takes up space.

### Desired Behavior

Replace the always-visible note box with a right-click context menu flow.

Right-clicking an item should open a context menu with:

- Leave note

Choosing **Leave note** should open a small edit UI/popover/modal with:

- Text field.
- Confirm button.
- Cancel button.

### Acceptance Criteria

- Note textbox is not permanently visible at the bottom of the loot browser.
- Right-click item context menu exists.
- Leave-note flow is clear and compact.
- Confirm/cancel behavior is explicit.

---

## 18. Roster Module: Scrollbar Position

### Problem

The roster module has the same scrollbar placement bug as the loot session item list.

Location:

- Roster module.
- Player names list.

### Desired Behavior

Move the scrollbar inside the list panel on the correct edge, instead of outside/on the wrong side of the divider.

### Acceptance Criteria

- Roster scrollbar visually belongs to the roster list.
- It is not misplaced outside the panel.
- Positioning matches the corrected session item list behavior.

---

## Suggested Implementation Priorities

1. Loot frame visibility model.
2. Session persistence/minimize behavior.
3. Award feedback/correction flow.
4. Loot session frame layout fixes.
5. Loot browser usability improvements.
6. Shared row readability styling.
7. Gargul-style trade timers.
8. Roster scrollbar/list polish.

## Do Not Do

- Do not make non-master-looters able to award, override, or end real sessions.
- Do not block normal raider/council participation while implementing visibility restrictions.
- Do not expose council votes/responses/notes to non-council members by default.
- Do not erase active sessions on reload/disconnect.
- Do not treat closing the session window as ending the session.
- Do not leave fake metadata like `(Token)` in the user notes area.
- Do not break per-item instance tracking when visually grouping duplicate drops.
- Do not duplicate row-striping logic separately in every frame if a shared helper/style is practical.
