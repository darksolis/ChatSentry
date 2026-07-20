ChatSentry v1.7.5
=================

A standalone World of Warcraft 3.3.5a chat filtering addon.

INSTALL
1. Extract the ChatSentry folder into Interface\AddOns\
2. Restart the game or type /reload
3. Open with /cs, /chatsentry, or the minimap button.

FEATURES
- Block messages containing custom words or phrases
- Block specific players
- Exact-word or contains matching
- Per-channel filtering
- Whitelist trusted players
- Searchable blocked-message history
- Session and lifetime statistics
- Minimap launcher
- Import/export lists
- Smart spam protection for repeats, bursts, and common trade formats

NEW IN v1.6.1
- Fixed Dashboard and Smart Filters panels extending outside their content frames.
- Corrected fixed-height callout panels so they stay inside the window.
- Second-pass professional UI overhaul.
- Cleaner sidebar with icons and active-state highlighting.
- Stronger section framing, cleaner table presentation, and more premium dashboard cards.
- Improved readability for toggles, filters, and lists.
- Updated header status pill and overall visual hierarchy.

RECENT CHANGES
- v1.5.0: Initial clean UI refresh inspired by Market Watch and DarkTracker.
- v1.4.2: Fixed repeat + burst rapid-fire tracking so both counters advance on every public message.
- v1.4.1: Ignores LootCollector protocol packets such as LC1:CONF:.
- v1.4.0: Added smart filters, currency detection, placeholder mode, and channel-recognition improvements.


v1.6.2
- Added a scrollbar to Dashboard Recent Blocks.
- Constrained long sender, channel, reason, and message text to their rows.
- Tightened Blocked Log row widths so text stays inside the window.


v1.6.3
- Dashboard footer status now switches between Active and Disabled with the main filtering toggle.
- Updated the displayed addon version in the footer.


v1.6.4
- Reduced Blocked Log to the number of rows that physically fit inside the panel.
- Tightened log text widths and truncation so messages remain inside the window.
- Ignores leaked BLFG addon protocol packets and removes old BLFG entries from the visible log.


v1.7.4
- Rebuilt directly from the user-confirmed working v1.6.4 codebase.
- Added one conservative Smart Filter for likely non-English messages.
- Includes non-Latin scripts and Latin-alphabet Spanish, Portuguese, French, and Italian signals.
- Original v1.6.4 minimap button code is unchanged.


v1.7.5
- Reworked Spanish detection with stricter grammar, phrase, accent, and trade-language scoring.
- Better detection of short Spanish trade messages such as vendo, compro, busco, and necesito.
- Preserved the working v1.6.4 minimap and UI code.
