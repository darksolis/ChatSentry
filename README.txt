ChatSentry v1.8.3
=================

A standalone World of Warcraft 3.3.5a chat filtering and moderation addon,
built for standard chat frames and private-server global channel panels.

INSTALLATION
1. Extract the ChatSentry folder into:
   World of Warcraft\Interface\AddOns\
2. Restart the game or type /reload.
3. Open ChatSentry with /cs, /chatsentry, or the minimap button.

CORE FEATURES
- Block messages containing custom words or literal phrases.
- Whole-word matching to avoid accidental partial matches.
- Block specific players.
- Whitelist trusted players.
- Enable filtering independently by chat channel.
- Searchable blocked-message history.
- Session and lifetime statistics.
- Import and export word, user, and whitelist lists.
- Movable minimap launcher.

SMART FILTERS
- Repeated-message protection.
- Rapid sender-burst protection.
- Automatic Donation Points / DP detection.
- Automatic Bazaar Tokens / BT detection.
- Contextual boost and carry advertising detection.
- Contextual guild recruitment detection.
- LFG traffic detection.
- External website filtering while preserving WoW item links.
- Optional placeholder mode instead of fully hiding blocked messages.
- Non-English language filtering.

LANGUAGE DETECTION
The language filter uses multiple independent signals instead of blocking on one
shared word. It includes:
- Phrase-first Spanish and Portuguese detection.
- Weighted distinctive vocabulary.
- Grammar and common function-word scoring.
- Language-specific suffixes.
- Accented-character and punctuation signals.
- English evidence that lowers false-positive scores.
- Non-Latin script detection.

Shared WoW terms such as raid, arena, guild, party, healer, DPS, and BG do not
count as foreign-language evidence by themselves.

COMPATIBILITY
- Supports World of Warcraft 3.3.5a.
- Includes a compatibility bridge for private-server chat panels.
- Ignores LootCollector protocol traffic such as LC1:CONF:.
- Ignores leaked BLFG addon protocol packets.
- Preserves the stable v1.6.4 minimap implementation.

MINIMAP CONTROLS
- Left-click: Open the Dashboard.
- Right-click: Open Settings.
- Shift-click: Toggle filtering on or off.

SLASH COMMANDS
- /cs
- /chatsentry
- /cs add <word or phrase>
- /cs user <player name>
- /cs on
- /cs off

VERSION 1.8.1
- Corrected every release-version reference so the .toc, Lua header, in-game
  footer, archive name, and README all report the same version.
- Rebuilt and reorganized the README to accurately document the current addon.
- No filtering, minimap, UI, language-detection, or saved-variable behavior was
  changed in this metadata correction release.

VERSION 1.8.0
- Rebuilt language filtering with phrase-first weighted Spanish and Portuguese
  detection.
- Added grammar, suffix, distinctive vocabulary, accent, and English-evidence
  scoring.
- Avoided treating shared WoW terms as language evidence by themselves.

VERSION 1.7.5
- Tightened Spanish detection using grammar, phrase, accent, and trade-language
  scoring.

VERSION 1.6.4
- Constrained Blocked Log text to the window.
- Ignored BLFG protocol packets.
- Used as the confirmed stable base for later releases.

Author: Darksolis


v1.8.2
- Fixed a Lua 5.1 syntax error introduced by the language-detector merge.
- The Portuguese word "do" is now stored with bracket notation because "do" is a reserved Lua keyword.
- No filtering behavior, UI layout, minimap behavior, or saved settings were otherwise changed.


v1.8.3
- Reworked Spanish detection into an aggressive blocking mode.
- Blocks many distinctive Spanish words even in one- or two-word messages.
- Added broader Spanish greetings, grammar, trade, group, recruitment, WoW, and slang vocabulary.
- Lowered Spanish scoring thresholds and added multi-marker grammar detection.
- Existing UI, minimap, saved settings, chat bridge, and non-language filters were not changed.
