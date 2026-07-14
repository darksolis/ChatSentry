ChatSentry v1.4.1
=================

A standalone World of Warcraft 3.3.5a chat filtering addon.

INSTALL
1. Extract the ChatSentry folder into Interface\\AddOns\\
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

NOTES
- ChatSentry hides messages locally. It does not stop the server from sending them.
- Item links and colored text are safely normalized before matching.

Minimap controls:
- Left-click: Open Dashboard
- Right-click: Open Settings
- Shift-click: Toggle filtering on or off


v1.2.0
- Added private-server global-channel compatibility bridge.
- Clarified that channel toggles enable filtering and never mute a whole channel.
- Improved literal phrase and whole-word matching.
- Added a message test tool to identify the exact matching keyword.
- Cleaned spacing, labels, and navigation.


v1.4.0
- Added dedicated Dashboard toggles for Donation Points / DP and Bazaar Tokens / BT.
- Quick toggles stay synchronized with the blocked-word list.
- Enabling a quick filter automatically creates any missing full-name or abbreviation entries.
- Bracketed entries such as [Bazaar Tokens] are recognized as the same quick-filter phrase.


v1.4.0
- DP and BT quick filters now catch compact price formats such as 35DP, 1,350BT, and 35xDP.
- Compact matching remains limited to the dedicated currency abbreviations to avoid false positives in normal words.


Version 1.4.0
- Added repeat-message and rapid-burst protection for public chat.
- Added smart DP/BT, boost, guild recruitment, LFG, and external-link filters.
- Added multi-layer custom channel recognition.
- Added optional placeholder mode and strengthened duplicate-log suppression.


Version 1.4.1
- Ignores LootCollector protocol packets such as LC1:CONF:.
- These hidden addon messages are no longer filtered, logged, or counted by spam protection.
