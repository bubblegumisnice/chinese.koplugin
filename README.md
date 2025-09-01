# Chinese Support Plugin for KOReader

Provides integration with a StarDict headword lexicon for Chinese.  

Implements efficient longest-match selection using headwords,  
with final display handled through KOReader’s built-in dictionary system.  

> **Note:** You must specify the path to the dictionary in `main.lua` (line 196).  

---

## Features
- Extends KOReader’s dictionary and text selection system to support Chinese.  
- Performs efficient scanning and longest-match word lookup.  
- Integrates seamlessly with KOReader’s built-in dictionary display system.  
- Adds an option under **Document → Language support plugins → Chinese** where the lexicon can be toggled on/off without disabling the plugin fully.  

---

## Requirements
- At least one installed Chinese dictionary.  
  - **Recommended**: [CEDICT (StarDict version)](https://github.com/liamsaliba/cc-cedict-stardict/releases).  

---

## Installation
1. Copy this plugin to:  
   `frontend/apps/plugins/chinese.koplugin/`
2. Ensure that the required dictionary files (`*.ifo` and `*.idx`) are present.  
3. Edit `main.lua` to specify the dictionary path on **line 210** (including the dictionary filename without the file extension).  
4. Restart KOReader.  

---

## Licence
Copyright (C) 2025  
Licensed under the GNU General Public License v3 or later.  
