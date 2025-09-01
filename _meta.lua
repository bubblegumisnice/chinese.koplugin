local _ = require("gettext")

return {
    name = "chinese",
    fullname = _("Chinese Support"),
    description = _([[
Chinese language support for KOReader.  
Provides integration with a StarDict headword lexicon.

Implements efficient longest-match selection using headwords,
with final display handled through KOReader’s built-in dictionary system.

Features:
• Extends KOReader’s dictionary and text selection system to handle Chinese.  
• Provides efficient scanning and longest-match word lookup.  
• Requires at least one installed Chinese dictionary (CEDICT is recommended 
and freely available online) - you must specify the path in main.lua.
• Adds an option under **Document → Language support plugins → Chinese** where the lexicon can be toggled on/off without disabling the plugin fully. 
    ]]),
}
