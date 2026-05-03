# KosmoNotes consumerization UX design

**Date:** 2026-05-03  
**Scope:** make KosmoNotes easier for office workers and managers without removing power-user depth  
**Primary audience:** non-developer knowledge workers, especially office workers and managers  
**Secondary audience:** existing power users who still need advanced control

## Problem

KosmoNotes is already feature-rich, but too much of its internal complexity is visible too early. The product often asks users to think in terms of providers, codecs, storage profiles, process taps, and advanced tabs before they have completed a simple task.

That makes the product feel like a tool for technical users. Office workers should instead experience it as a simple voice workspace with a clear path to four tasks:

1. record a meeting
2. dictate text
3. save a voice note
4. find a past recording

The design goal is not to remove capability. The goal is to hide complexity until the user needs it.

## Design goal

KosmoNotes should feel simple on the default path, explicit when something fails, and deep only when the user asks for depth.

This design uses one principle throughout the product: **progressive disclosure**. The UI should reveal:

1. the core action first
2. the minimum settings needed for success next
3. advanced controls only when the user chooses to go deeper

## Product model

The product should present itself as a voice workspace, not as a bundle of audio and AI infrastructure.

### Core product surface

The default product surface should expose four top-level actions:

1. **Record meeting**
2. **Dictate text**
3. **Quick voice note**
4. **Open library**

These actions should appear in the menu bar, onboarding, and empty states. They should be described by outcome, not by implementation.

### Advanced product surface

The following features remain available, but they should move behind advanced settings or secondary flows:

- AI provider selection
- transcription provider selection
- process tap configuration
- storage profile and codec controls
- streaming
- markdown export
- agent features
- provider routing and model tuning

This keeps the product capable without forcing ordinary users to form opinions on infrastructure.

## Critical UX problems and intended fixes

### 1. Onboarding starts with permissions, not success

The current onboarding explains permissions clearly, but it does not guide the user to a first successful task. That creates friction at the most fragile moment in the product.

### Design change

Replace the static permission-first onboarding with a short guided setup:

1. ask what the user wants to do first
   - Record meetings
   - Dictate text
   - Capture voice notes
2. request only the permissions needed for that choice
3. offer a short test action
   - 10-second meeting test
   - short dictation test
   - quick voice note test
4. show the result immediately

### Result

The user learns the product through success, not through system dialogs.

### 2. The menu bar is functional, but not self-explanatory

The current menu is strong for an experienced user, but its mental model is still thin for a new one. “Start Recording” and “Start Voice Note” are clear only if the user already understands the product’s modes.

### Design change

Rename primary actions by user intent:

- **Record meeting**
- **Dictate text**
- **Quick voice note**
- **My recordings**

Show live state directly in the menu:

- Recording
- Processing
- Ready
- Permission needed

Add one-line helper copy under the first-run state or near the main actions:

- Meeting mode records mic and optional system audio
- Dictation pastes text into the active app
- Voice note turns speech into a structured note

### Result

The menu bar becomes the product’s home screen instead of a control panel.

### 3. Settings mix basic and advanced concerns

This is the largest usability issue in the current product. The settings window mixes ordinary user needs with engineering-grade configuration.

### Design change

Reorganize settings into two levels.

### Primary settings

- **General**
- **Recording**
- **AI and transcription**
- **Privacy and sharing**

### Advanced settings

- **Advanced**
  - provider routing
  - process tap
  - streaming
  - markdown export
  - agent features
  - codec and bitrate details

### Additional rule

Every advanced setting must answer one question in plain language:

**What does this change for the user?**

If the UI cannot answer that, the setting is too raw for a mainstream surface.

### Result

Office workers see only the controls they can act on confidently. Power users still get full control.

### 4. The product thinks in providers more than user goals

Provider-first UX leaks infrastructure into user decisions. Most office workers do not want to choose between Deepgram, OpenAI Whisper, Gemini, or OpenRouter before they know whether the product helps them.

### Design change

Shift the default language from provider choice to outcome choice.

Examples:

- instead of “Transcription provider,” use **Transcription quality and speed**
- instead of “Storage profile,” use **Recording quality**
- instead of codec labels, use **Best quality / Balanced / Save space**

Provider selection can remain in advanced settings or behind an “Expert” disclosure.

### Result

Users think in goals and trade-offs they understand.

### 5. The library behaves more like an archive than a result screen

The library already does a lot. The issue is not missing power. The issue is emphasis. After recording, ordinary users want answers first and media controls second.

### Design change

Restructure the detail view so the top of the screen prioritizes result blocks:

1. Summary
2. Action items
3. Share
4. Export
5. Ask

Playback and transcript remain present, but they should support the result rather than dominate the first impression.

### Result

Users move from “I recorded something” to “I got something useful.”

## Target information architecture

### Default path

The default path should be short and readable:

1. choose task
2. grant the required permission
3. record or dictate
4. receive result
5. find it later in the library

At no point on this path should the user need to understand provider routing, audio codecs, or advanced capture choices.

### Advanced path

Advanced controls remain available through:

- a dedicated Advanced section in settings
- secondary controls in record setup
- optional pro-oriented tabs and disclosures

The advanced path should never interrupt the default path.

## Data flow and user flow

The product flow should map to user expectations:

1. **Before capture**
   - user chooses a task
   - product explains what will be captured
   - product checks permissions
2. **During capture**
   - product shows clear status
   - product shows whether system audio is included
3. **After capture**
   - product shows processing status
   - product shows what was produced
     - transcript
     - summary
     - action items
     - voice note structure
4. **After processing**
   - user can open, share, export, or ask follow-up questions

This data flow matters because the current product often handles the pipeline correctly in code but does not always explain its state clearly in the UI.

## Error handling

The current product tolerates partial failures, but it often hides them. That is acceptable for internal development. It is weak for a user-facing release.

### Design rule

Every partial failure should be expressed in a user-readable way:

- **Transcript ready, summary unavailable**
- **System audio not captured because Screen Recording permission is off**
- **Sharing unavailable until cloud storage is configured**
- **Semantic search unavailable; basic search is still on**

### Message standard

Each message should answer three things:

1. what worked
2. what did not work
3. what to do next

### Result

Users stop confusing “missing result” with “broken product.”

## Copy and naming

The product should remove developer-facing naming from the mainstream path.

### Preferred naming

- Record meeting
- Dictate text
- Quick voice note
- My recordings
- Recording quality
- Language
- Sharing
- Privacy
- Advanced

### Naming to hide or demote

- provider names as first-class choices
- codec names
- process tap terminology
- agent terminology
- storage profile terminology

These terms may remain in advanced surfaces, but not as primary product language.

## Visual design implications

The product should look calmer and more mainstream through hierarchy, not decoration.

### Visual rules

- fewer tabs visible by default
- stronger separation between primary and advanced actions
- more explanatory empty states
- clearer capture states
- result-first post-recording screens

The product does not need more visual flourish. It needs clearer hierarchy and fewer early decisions.

## Validation plan

If implemented, this design should be validated through usability checks, not only technical correctness.

### Success criteria

1. a new office worker can complete a first recording without reading docs
2. a new user can explain the difference between the three capture modes after first-run setup
3. a user can find transcript, summary, and export quickly after recording
4. a user never needs to understand providers to complete the default path
5. advanced users still retain access to all current controls

### Test scenarios

- first-run meeting recording
- first-run dictation
- first-run voice note
- locating a past recording
- sharing a completed result
- encountering one partial failure

## Scope boundaries

This design does **not** propose:

- removing advanced features
- changing the core storage or provider architecture
- turning the product into a team SaaS workspace
- redesigning the full visual language from scratch

This design **does** propose:

- changing product language
- reorganizing settings and flows
- improving onboarding
- making states and failures explicit
- separating mainstream and advanced UX

## Recommendation

KosmoNotes should keep its depth, but stop presenting that depth as the default experience.

The product should feel simple first, guided second, and advanced only on request. That is the cleanest way to make it useful to office workers and managers without weakening it for power users.
